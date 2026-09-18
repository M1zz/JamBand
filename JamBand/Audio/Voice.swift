import Foundation

/// Sound design for one part. Kept deliberately tiny so the whole app has no
/// sample library and no licensing questions — every sound is synthesized.
struct Patch {
    enum Wave { case sine, triangle, saw, square }

    var wave: Wave = .saw
    var attack: Float = 0.005      // seconds
    var decay: Float = 0.1         // seconds
    var sustain: Float = 0.7       // 0...1
    var release: Float = 0.2       // seconds
    var cutoff: Float = 0.3        // one-pole low-pass coefficient, 1 = bypass
    var gain: Float = 0.5
    var detune: Float = 0          // cents for a second oscillator; 0 = single osc
    var isDrumKit = false
}

/// General MIDI drum numbers so the note data reads like a normal MIDI track.
enum DrumKind: Int {
    case kick = 36
    case snare = 38
    case hatClosed = 42
    case hatOpen = 46

    var length: Float {
        switch self {
        case .kick: return 0.5
        case .snare: return 0.35
        case .hatClosed: return 0.12
        case .hatOpen: return 0.6
        }
    }
}

/// A single polyphonic voice. Value type, preallocated in a pool, and rendered
/// on the audio thread with no allocation.
struct Voice {
    enum Stage { case off, attack, decay, sustain, release }

    var active = false
    var order = 0                    // allocation order, used for voice stealing

    private var patch = Patch()
    private var freq: Float = 440
    private var freq2: Float = 440
    private var velocity: Float = 1
    private var phase: Float = 0
    private var phase2: Float = 0
    private var env: Float = 0
    private var stage: Stage = .off
    private var gateRemaining = 0    // frames until note-off
    private var delay = 0            // frames to wait before the note begins
    private var elapsed = 0          // frames since the note began (drums)
    private var lp: Float = 0
    private var noisePrev: Float = 0
    private var rng: UInt32 = 0x9E37_79B9
    private var drum: DrumKind?
    private var attackInc: Float = 0
    private var decayDec: Float = 0
    private var releaseMul: Float = 0

    mutating func start(patch: Patch, pitch: Int, velocity: Float, gateFrames: Int, delay: Int, sampleRate sr: Float, order: Int) {
        self.patch = patch
        self.velocity = velocity
        self.delay = delay
        self.order = order
        elapsed = 0
        phase = 0
        phase2 = 0
        lp = 0
        noisePrev = 0
        active = true

        if patch.isDrumKit {
            drum = DrumKind(rawValue: pitch) ?? .hatClosed
            env = 1
            stage = .sustain
            gateRemaining = 0
        } else {
            drum = nil
            freq = 440 * powf(2, Float(pitch - 69) / 12)
            freq2 = freq * powf(2, patch.detune / 1200)
            env = 0
            stage = .attack
            gateRemaining = max(gateFrames, 1)
            attackInc = 1 / max(patch.attack * sr, 1)
            decayDec = (1 - patch.sustain) / max(patch.decay * sr, 1)
            releaseMul = expf(-5 / max(patch.release * sr, 1))
        }
    }

    /// Force the voice into its release phase (used on stop).
    mutating func release() {
        guard active else { return }
        if drum != nil {
            active = false
            stage = .off
        } else {
            gateRemaining = 0
            stage = .release
        }
    }

    /// Adds this voice's output into `out` (mono).
    mutating func render(into out: UnsafeMutablePointer<Float>, frames: Int, sampleRate sr: Float) {
        var start = 0
        if delay > 0 {
            let skip = min(delay, frames)
            delay -= skip
            start = skip
            if start >= frames { return }
        }
        if let kind = drum {
            renderDrum(kind, into: out, from: start, to: frames, sampleRate: sr)
        } else {
            renderTone(into: out, from: start, to: frames, sampleRate: sr)
        }
    }

    // MARK: - Tonal

    private mutating func renderTone(into out: UnsafeMutablePointer<Float>, from start: Int, to end: Int, sampleRate sr: Float) {
        let inc1 = freq / sr
        let inc2 = freq2 / sr
        let dual = patch.detune != 0
        let amp = velocity * patch.gain
        let cutoff = patch.cutoff
        let sustain = patch.sustain
        let wave = patch.wave

        var i = start
        while i < end {
            if gateRemaining > 0 {
                gateRemaining -= 1
                if gateRemaining == 0 { stage = .release }
            }

            switch stage {
            case .attack:
                env += attackInc
                if env >= 1 { env = 1; stage = .decay }
            case .decay:
                env -= decayDec
                if env <= sustain { env = sustain; stage = .sustain }
            case .sustain:
                break
            case .release:
                env *= releaseMul
                if env < 0.001 { active = false; stage = .off; return }
            case .off:
                active = false
                return
            }

            var s = Voice.wave(wave, phase)
            phase += inc1
            if phase >= 1 { phase -= 1 }
            if dual {
                s = 0.5 * (s + Voice.wave(wave, phase2))
                phase2 += inc2
                if phase2 >= 1 { phase2 -= 1 }
            }
            lp += cutoff * (s - lp)
            out[i] += lp * env * amp
            i += 1
        }
    }

    private static func wave(_ w: Patch.Wave, _ p: Float) -> Float {
        switch w {
        case .sine: return sinf(2 * Float.pi * p)
        case .triangle: return 4 * abs(p - 0.5) - 1
        case .saw: return 2 * p - 1
        case .square: return p < 0.5 ? 1 : -1
        }
    }

    // MARK: - Drums

    private mutating func renderDrum(_ kind: DrumKind, into out: UnsafeMutablePointer<Float>, from start: Int, to end: Int, sampleRate sr: Float) {
        let amp = velocity * patch.gain
        let length = kind.length

        var i = start
        while i < end {
            let t = Float(elapsed) / sr
            if t >= length { active = false; stage = .off; return }

            var s: Float = 0
            switch kind {
            case .kick:
                let f = 45 + 130 * expf(-t * 35)          // pitch sweep
                phase += f / sr
                if phase >= 1 { phase -= 1 }
                s = sinf(2 * Float.pi * phase) * expf(-t * 7) * 1.2 + noise() * expf(-t * 200) * 0.3
            case .snare:
                phase += 190 / sr
                if phase >= 1 { phase -= 1 }
                s = noise() * expf(-t * 16) * 0.7 + sinf(2 * Float.pi * phase) * expf(-t * 30) * 0.5
            case .hatClosed:
                let nz = noise()
                let hp = nz - noisePrev                     // crude high-pass
                noisePrev = nz
                s = hp * expf(-t * 55) * 0.5
            case .hatOpen:
                let nz = noise()
                let hp = nz - noisePrev
                noisePrev = nz
                s = hp * expf(-t * 9) * 0.4
            }

            out[i] += s * amp
            elapsed += 1
            i += 1
        }
    }

    private mutating func noise() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng) * (2 / Float(UInt32.max)) - 1
    }
}
