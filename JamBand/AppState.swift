import Foundation
import Observation
import MultipeerConnectivity
import UIKit

/// Single source of truth for the UI. Owns the network session and the synth.
///
/// Sync model:
/// - The peer with the smallest display name is the *leader*. No handshake
///   needed; every device computes the same answer from the same peer list.
/// - Followers ping the leader once a second. Each round trip yields an offset
///   estimate (leaderClock - localClock); we keep the one with the lowest RTT.
/// - When everyone is ready, the leader picks `now + 3s` on its own clock and
///   broadcasts it. Followers convert to local time with their offset and hand
///   the result to the synth, which schedules sample-accurately from there.
@Observable
final class AppState {
    enum Phase: Equatable { case lobby, countdown, playing }

    let instruments: [Instrument] = [
        Instrument(id: 0, name: "드럼", emoji: "🥁", color: .orange),
        Instrument(id: 1, name: "베이스", emoji: "🎸", color: .red),
        Instrument(id: 2, name: "키보드", emoji: "🎹", color: .blue),
        Instrument(id: 3, name: "리드", emoji: "🎷", color: .purple),
        Instrument(id: 4, name: "패드", emoji: "🎻", color: .teal),
        Instrument(id: 5, name: "아르페지오", emoji: "✨", color: .pink),
    ]

    let song: Song

    private(set) var me: PeerState
    private(set) var peers: [String: PeerState] = [:]
    private(set) var phase: Phase = .lobby
    private(set) var startTime: Double?
    private(set) var clockOffset: Double = 0
    private(set) var clockSynced = false
    private(set) var lastRTT: Double = 0
    private(set) var audioError: String?

    private let session: SessionManager
    private let synth: SynthEngine
    @ObservationIgnored private var offsetSamples: [(offset: Double, rtt: Double)] = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastLeader = ""

    init() {
        let song = Song.demo()
        self.song = song

        let device = UIDevice.current.name.prefix(20)
        let suffix = String(UInt16.random(in: 0...UInt16.max), radix: 16, uppercase: true)
        let name = "\(device)#\(suffix)"

        me = PeerState(name: name, instrument: nil, ready: false)
        session = SessionManager(displayName: name)
        synth = SynthEngine(song: song)
        lastLeader = name
        clockSynced = true   // alone => I am the leader => my clock is the reference

        session.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.peersChanged(peers) }
        }
        session.onMessage = { [weak self] message, peer, receivedAt in
            Task { @MainActor in self?.handle(message, from: peer, receivedAt: receivedAt) }
        }
    }

    // MARK: - Derived state

    var leaderName: String { ([me.name] + Array(peers.keys)).min() ?? me.name }
    var isLeader: Bool { leaderName == me.name }
    var participantCount: Int { peers.count + 1 }
    var participants: [PeerState] { [me] + peers.values.sorted { $0.name < $1.name } }
    var canReady: Bool { me.instrument != nil && (isLeader || clockSynced) }

    var myInstrument: Instrument? {
        me.instrument.flatMap { id in instruments.first { $0.id == id } }
    }

    func instrument(for id: Int?) -> Instrument? {
        id.flatMap { id in instruments.first { $0.id == id } }
    }

    func owners(of instrumentID: Int) -> [String] {
        participants.filter { $0.instrument == instrumentID }.map { displayName(for: $0) }
    }

    /// Strips the random suffix and marks the local device.
    func displayName(for peer: PeerState) -> String {
        let base = peer.name.split(separator: "#").first.map(String.init) ?? peer.name
        return peer.name == me.name ? "나 (\(base))" : base
    }

    // MARK: - Lifecycle

    func startServices() {
        guard !started else { return }
        started = true

        do {
            try synth.start()
        } catch {
            audioError = error.localizedDescription
        }
        session.start()

        syncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sendPing()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - User actions

    func selectInstrument(_ id: Int) {
        me.instrument = id
        me.ready = false
        synth.setPart(id)
        synth.preview(part: id)
        session.send(.state(me))
    }

    func toggleReady() {
        guard canReady else { return }
        me.ready.toggle()
        session.send(.state(me))
        checkAutoStart()
    }

    func stopPlayback(broadcast: Bool) {
        synth.stop()
        phase = .lobby
        startTime = nil
        setIdleTimerDisabled(false)
        me.ready = false
        for key in peers.keys { peers[key]?.ready = false }
        if broadcast { session.send(.stop) }
        session.send(.state(me))
    }

    // MARK: - Network events

    private func peersChanged(_ connected: [MCPeerID]) {
        var updated: [String: PeerState] = [:]
        var newcomers: [MCPeerID] = []
        for peer in connected {
            if let existing = peers[peer.displayName] {
                updated[peer.displayName] = existing
            } else {
                updated[peer.displayName] = PeerState(name: peer.displayName, instrument: nil, ready: false)
                newcomers.append(peer)
            }
        }
        peers = updated

        if !newcomers.isEmpty {
            session.send(.state(me), to: newcomers)
            // Late joiners during a jam get the original start time so they fall in step.
            if isLeader, phase != .lobby, let start = startTime {
                session.send(.start(leaderTime: start, bpm: song.bpm), to: newcomers)
            }
        }

        let leader = leaderName
        if leader != lastLeader {
            lastLeader = leader
            offsetSamples.removeAll()
            clockOffset = 0
            clockSynced = isLeader
            sendPing()
        }

        checkAutoStart()
    }

    private func handle(_ message: NetMessage, from peer: MCPeerID, receivedAt: Double) {
        switch message {
        case .state(let state):
            peers[peer.displayName] = state
            checkAutoStart()

        case .ping(let t0):
            session.send(.pong(t0: t0, t1: Clock.now()), to: [peer], reliable: false)

        case .pong(let t0, let t1):
            guard peer.displayName == leaderName else { return }
            let rtt = receivedAt - t0
            let offset = t1 - (t0 + receivedAt) / 2
            offsetSamples.append((offset: offset, rtt: rtt))
            if offsetSamples.count > 8 { offsetSamples.removeFirst() }
            if let best = offsetSamples.min(by: { $0.rtt < $1.rtt }) {
                clockOffset = best.offset
                lastRTT = best.rtt
            }
            if offsetSamples.count >= 3 { clockSynced = true }

        case .start(let leaderTime, let bpm):
            guard peer.displayName == leaderName else { return }
            beginPlayback(localStart: leaderTime - clockOffset, bpm: bpm)

        case .stop:
            stopPlayback(broadcast: false)
        }
    }

    private func sendPing() {
        guard !isLeader,
              let leader = session.connectedPeers.first(where: { $0.displayName == leaderName }) else { return }
        session.send(.ping(t0: Clock.now()), to: [leader], reliable: false)
    }

    // MARK: - Playback

    private func setIdleTimerDisabled(_ disabled: Bool) {
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = disabled }
    }

    private func checkAutoStart() {
        guard isLeader, phase == .lobby, me.ready, me.instrument != nil else { return }
        guard peers.values.allSatisfy({ $0.ready && $0.instrument != nil }) else { return }

        let start = Clock.now() + 3.0
        session.send(.start(leaderTime: start, bpm: song.bpm))
        beginPlayback(localStart: start, bpm: song.bpm)
    }

    private func beginPlayback(localStart: Double, bpm: Double) {
        startTime = localStart
        synth.play(at: localStart, bpm: bpm)
        setIdleTimerDisabled(true)

        let delay = localStart - Clock.now()
        if delay > 0 {
            phase = .countdown
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.startTime == localStart, self.phase == .countdown else { return }
                self.phase = .playing
            }
        } else {
            phase = .playing
        }
    }
}
