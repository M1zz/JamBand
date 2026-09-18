import Foundation

/// A note event inside a loop. `beat` is measured in quarter notes from loop start.
/// For drum parts, `pitch` holds a `DrumKind` raw value (GM drum numbers).
struct Note {
    let beat: Double
    let pitch: Int
    let duration: Double   // in beats
    let velocity: Float    // 0...1
}

/// One instrument track. Each device plays exactly one part.
struct Part {
    let name: String
    let patch: Patch
    let notes: [Note]      // must be sorted by beat
    let gain: Float
}

struct Song {
    let bpm: Double
    let beatsPerBar: Int
    let bars: Int
    let parts: [Part]

    var loopBeats: Double { Double(bars * beatsPerBar) }
}

// MARK: - Demo song

extension Song {
    /// An 8-bar loop in A minor (Am – F – C – G) at 112 BPM with six parts:
    /// drums, bass, keys, lead, pad, arpeggio. Everything is generated
    /// procedurally except the lead melody, which is written by hand.
    static func demo() -> Song {
        let bpm = 112.0
        let bars = 8
        let beatsPerBar = 4

        // Roots (bass register) and 3-note voicings for Am, F, C, G.
        let roots = [45, 41, 48, 43]
        let chords: [[Int]] = [[57, 60, 64], [53, 57, 60], [55, 60, 64], [55, 59, 62]]

        func n(_ beat: Double, _ pitch: Int, _ duration: Double, _ velocity: Float = 0.8) -> Note {
            Note(beat: beat, pitch: pitch, duration: duration, velocity: velocity)
        }

        var drums: [Note] = []
        var bass: [Note] = []
        var keys: [Note] = []
        var pad: [Note] = []
        var arp: [Note] = []

        for bar in 0..<bars {
            let b0 = Double(bar * beatsPerBar)
            let idx = bar % 4
            let root = roots[idx]
            let chord = chords[idx]

            // Drums: kick on 1 and the "and" of 3, snare on 2 and 4, 8th-note hats.
            drums.append(n(b0, DrumKind.kick.rawValue, 0.1, 1.0))
            drums.append(n(b0 + 2.5, DrumKind.kick.rawValue, 0.1, 0.9))
            if bar % 4 == 3 { drums.append(n(b0 + 3.5, DrumKind.kick.rawValue, 0.1, 0.8)) }
            drums.append(n(b0 + 1, DrumKind.snare.rawValue, 0.1, 0.9))
            drums.append(n(b0 + 3, DrumKind.snare.rawValue, 0.1, 0.9))
            for i in 0..<8 {
                let pos = b0 + Double(i) * 0.5
                if i == 7 && bar % 2 == 1 {
                    drums.append(n(pos, DrumKind.hatOpen.rawValue, 0.1, 0.6))
                } else {
                    drums.append(n(pos, DrumKind.hatClosed.rawValue, 0.1, i % 2 == 0 ? 0.6 : 0.4))
                }
            }

            // Bass: driving 8ths on the root, octave pop on beat 2-and, fifth on the last 8th.
            for i in 0..<8 {
                let pitch = i == 7 ? root + 7 : (i == 3 ? root + 12 : root)
                bass.append(n(b0 + Double(i) * 0.5, pitch, 0.4, i % 2 == 0 ? 0.9 : 0.7))
            }

            // Keys: block chords on 1 and 3, short stab on 4-and.
            for p in chord {
                keys.append(n(b0, p, 1.8, 0.8))
                keys.append(n(b0 + 2, p, 1.3, 0.7))
                keys.append(n(b0 + 3.5, p, 0.4, 0.6))
            }

            // Pad: whole-note chord one octave down.
            for p in chord { pad.append(n(b0, p - 12, 4.0, 0.6)) }

            // Arp: 16th-note up/down pattern over chord tones + octave.
            let tones = chord + [chord[0] + 12]
            let pattern = [0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 0, 1, 2, 3]
            for (i, t) in pattern.enumerated() {
                arp.append(n(b0 + Double(i) * 0.25, tones[t], 0.2, i % 4 == 0 ? 0.7 : 0.5))
            }
        }

        // Lead melody (A minor pentatonic), two 4-bar phrases.
        let leadData: [(Double, Int, Double)] = [
            (0, 76, 1), (1, 79, 0.5), (1.5, 76, 0.5), (2, 74, 1), (3, 72, 1),
            (4, 69, 1.5), (5.5, 72, 0.5), (6, 74, 1), (7, 76, 1),
            (8, 79, 1), (9, 76, 0.5), (9.5, 74, 0.5), (10, 72, 1), (11, 74, 0.5), (11.5, 76, 0.5),
            (12, 74, 2), (14, 71, 1),
            (16, 76, 0.5), (16.5, 76, 0.5), (17, 79, 1), (18, 81, 1), (19, 79, 1),
            (20, 76, 1.5), (21.5, 74, 0.5), (22, 72, 1), (23, 69, 1),
            (24, 72, 1), (25, 74, 1), (26, 76, 1), (27, 79, 1),
            (28, 74, 3),
        ]
        let lead = leadData.map { n($0.0, $0.1, $0.2 * 0.9, 0.85) }

        func sorted(_ notes: [Note]) -> [Note] { notes.sorted { $0.beat < $1.beat } }

        let drumPatch = Patch(gain: 0.9, isDrumKit: true)
        let bassPatch = Patch(wave: .saw, attack: 0.005, decay: 0.15, sustain: 0.6, release: 0.08, cutoff: 0.08, gain: 0.6)
        let keysPatch = Patch(wave: .triangle, attack: 0.005, decay: 0.4, sustain: 0.3, release: 0.3, cutoff: 0.5, gain: 0.35, detune: 6)
        let leadPatch = Patch(wave: .saw, attack: 0.02, decay: 0.2, sustain: 0.6, release: 0.25, cutoff: 0.35, gain: 0.4, detune: 10)
        let padPatch = Patch(wave: .saw, attack: 0.6, decay: 0.5, sustain: 0.8, release: 0.8, cutoff: 0.12, gain: 0.25, detune: 12)
        let arpPatch = Patch(wave: .square, attack: 0.002, decay: 0.12, sustain: 0.0, release: 0.1, cutoff: 0.4, gain: 0.3)

        return Song(
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            bars: bars,
            parts: [
                Part(name: "Drums", patch: drumPatch, notes: sorted(drums), gain: 1.0),
                Part(name: "Bass", patch: bassPatch, notes: sorted(bass), gain: 1.0),
                Part(name: "Keys", patch: keysPatch, notes: sorted(keys), gain: 1.0),
                Part(name: "Lead", patch: leadPatch, notes: sorted(lead), gain: 1.0),
                Part(name: "Pad", patch: padPatch, notes: sorted(pad), gain: 1.0),
                Part(name: "Arp", patch: arpPatch, notes: sorted(arp), gain: 1.0),
            ]
        )
    }
}
