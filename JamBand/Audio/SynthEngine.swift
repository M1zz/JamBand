import AVFoundation
import os

enum SynthError: Error {
    case unsupportedFormat
}

/// Plays exactly one part of a `Song`, scheduled against the shared host clock.
///
/// The sequencer lives inside the render callback: on every buffer it converts
/// the buffer's host timestamp into a beat position and triggers any notes that
/// fall inside that buffer at their exact sample offset. Because every device
/// agrees on a start time (via `AppState`'s clock sync) and each device's audio
/// thread knows when its own buffer will hit the speaker, the phones stay in
/// sync without any ongoing network traffic.
final class SynthEngine {
    struct Transport {
        var playing = false
        var startTime: Double = 0    // host seconds when beat 0 plays
        var bpm: Double = 120
        var partIndex: Int = -1
        var previewPart: Int = -1    // one-shot request consumed by the render thread
        var killAll = false          // one-shot: release every voice
    }

    let song: Song
    private(set) var sampleRate: Double = 48_000

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let transport = OSAllocatedUnfairLock(initialState: Transport())
    private var voices = [Voice](repeating: Voice(), count: 24)
    private let scratchCapacity = 8192
    private let scratch: UnsafeMutablePointer<Float>
    private var noteCounter = 0
    private var outputLatency: Double = 0
    private let masterGain: Float = 0.8
    private var observingInterruptions = false

    init(song: Song) {
        self.song = song
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        scratch.deallocate()
    }

    // MARK: - Lifecycle

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        outputLatency = session.outputLatency

        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = hwRate > 0 ? hwRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw SynthError.unsupportedFormat
        }

        if sourceNode == nil {
            let node = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, abl in
                self.render(timestamp: timestamp, frameCount: frameCount, abl: abl)
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sourceNode = node
        }

        engine.prepare()
        try engine.start()
        observeInterruptions()
    }

    private func observeInterruptions() {
        guard !observingInterruptions else { return }
        observingInterruptions = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            try? self?.engine.start()
        }
    }

    // MARK: - Control (main thread)

    func setPart(_ index: Int) {
        transport.withLock { $0.partIndex = index }
    }

    /// Plays the notes that sit on beat 0 of a part, so the lobby can audition it.
    func preview(part: Int) {
        transport.withLock { $0.previewPart = part }
    }

    func play(at hostSeconds: Double, bpm: Double) {
        transport.withLock {
            $0.playing = true
            $0.startTime = hostSeconds
            $0.bpm = bpm
            $0.killAll = true
        }
    }

    func stop() {
        transport.withLock {
            $0.playing = false
            $0.killAll = true
        }
    }

    // MARK: - Render (audio thread)

    private func render(timestamp: UnsafePointer<AudioTimeStamp>,
                        frameCount: AVAudioFrameCount,
                        abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = Int(frameCount)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)

        guard frames <= scratchCapacity else {
            for buffer in buffers {
                if let p = buffer.mData { memset(p, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }

        // Snapshot the transport and consume one-shot requests under the lock.
        let t = transport.withLock { state -> Transport in
            let copy = state
            state.previewPart = -1
            state.killAll = false
            return copy
        }

        let sr = Float(sampleRate)
        scratch.update(repeating: 0, count: frames)

        if t.killAll {
            for i in voices.indices { voices[i].release() }
        }

        if t.previewPart >= 0 && t.previewPart < song.parts.count {
            let part = song.parts[t.previewPart]
            var count = 0
            for note in part.notes where note.beat == 0 && count < 4 {
                trigger(note, part: part, delay: 0, bpm: song.bpm, sr: sr)
                count += 1
            }
        }

        if t.playing, t.partIndex >= 0, t.partIndex < song.parts.count {
            let part = song.parts[t.partIndex]

            // When will the first frame of this buffer reach the speaker?
            var hostSeconds: Double
            if timestamp.pointee.mFlags.contains(.hostTimeValid) {
                hostSeconds = AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
            } else {
                hostSeconds = Clock.now()
            }
            hostSeconds += outputLatency

            let secPerBeat = 60.0 / t.bpm
            let beatStart = (hostSeconds - t.startTime) / secPerBeat
            let beatEnd = beatStart + Double(frames) / sampleRate / secPerBeat

            if beatEnd > 0 {
                let loop = song.loopBeats
                let kStart = max(0, Int(floor(beatStart / loop)))
                let kEnd = Int(floor(beatEnd / loop))
                for k in kStart...kEnd {
                    let base = Double(k) * loop
                    for note in part.notes {
                        let b = base + note.beat
                        if b < beatStart { continue }
                        if b >= beatEnd { break }
                        let delay = Int((b - beatStart) * secPerBeat * sampleRate)
                        trigger(note, part: part, delay: min(max(delay, 0), frames - 1), bpm: t.bpm, sr: sr)
                    }
                }
            }
        }

        for i in voices.indices where voices[i].active {
            voices[i].render(into: scratch, frames: frames, sampleRate: sr)
        }

        for buffer in buffers {
            guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            for i in 0..<count {
                p[i] = tanhf(scratch[i] * masterGain)
            }
        }
        return noErr
    }

    private func trigger(_ note: Note, part: Part, delay: Int, bpm: Double, sr: Float) {
        let secPerBeat = 60.0 / bpm
        let gate = Int(note.duration * secPerBeat * Double(sr))

        var slot = -1
        var oldest = 0
        var oldestOrder = Int.max
        for i in voices.indices {
            if !voices[i].active { slot = i; break }
            if voices[i].order < oldestOrder {
                oldestOrder = voices[i].order
                oldest = i
            }
        }
        if slot < 0 { slot = oldest }

        noteCounter += 1
        voices[slot].start(
            patch: part.patch,
            pitch: note.pitch,
            velocity: note.velocity * part.gain,
            gateFrames: gate,
            delay: delay,
            sampleRate: sr,
            order: noteCounter
        )
    }
}
