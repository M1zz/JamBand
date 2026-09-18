import AVFoundation

/// A monotonic clock expressed in seconds, using the same time base the audio
/// engine reports in its render callbacks (mach host time). All scheduling —
/// network sync, countdown UI, sample-accurate note triggering — runs on this.
enum Clock {
    static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    static func hostTime(forSeconds seconds: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: seconds)
    }
}
