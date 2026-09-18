import SwiftUI

/// An instrument a player can pick. `id` is the index into `Song.parts`.
struct Instrument: Identifiable {
    let id: Int
    let name: String
    let emoji: String
    let color: Color
}

/// What every device knows about every player (including itself).
struct PeerState: Codable, Equatable, Identifiable {
    var name: String
    var instrument: Int?
    var ready: Bool

    var id: String { name }
}

/// Everything that travels over MultipeerConnectivity, JSON-encoded.
enum NetMessage: Codable {
    /// Broadcast whenever a player changes instrument or ready state.
    case state(PeerState)
    /// Clock sync request from a follower to the leader (t0 = sender's host clock).
    case ping(t0: Double)
    /// Clock sync reply from the leader (t1 = leader's host clock at reply time).
    case pong(t0: Double, t1: Double)
    /// Leader schedules playback to begin at `leaderTime` (leader's host clock, seconds).
    case start(leaderTime: Double, bpm: Double)
    /// Anyone can stop the jam for everyone.
    case stop
}
