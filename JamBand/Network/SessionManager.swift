import Foundation
import MultipeerConnectivity

/// Thin wrapper over MultipeerConnectivity. Every device both advertises and
/// browses; to avoid two devices inviting each other simultaneously, only the
/// peer with the lexicographically smaller display name sends the invitation.
/// Everyone auto-accepts, so nearby devices form one mesh with no UI.
final class SessionManager: NSObject {
    static let serviceType = "jamband"   // must match NSBonjourServices in Info.plist

    let myPeerID: MCPeerID

    /// Called off the main thread whenever the connected peer list changes.
    var onPeersChanged: (([MCPeerID]) -> Void)?
    /// Called off the main thread for each received message. `receivedAt` is the
    /// host clock time at receipt, captured before any dispatch so ping/pong
    /// measurements are as tight as possible.
    var onMessage: ((NetMessage, MCPeerID, Double) -> Void)?

    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var connectedPeers: [MCPeerID] { session.connectedPeers }

    init(displayName: String) {
        myPeerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .none)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    /// Sends to the given peers, or to everyone when `peers` is nil.
    func send(_ message: NetMessage, to peers: [MCPeerID]? = nil, reliable: Bool = true) {
        let targets = peers ?? session.connectedPeers
        guard !targets.isEmpty, let data = try? encoder.encode(message) else { return }
        try? session.send(data, toPeers: targets, with: reliable ? .reliable : .unreliable)
    }
}

// MARK: - MCSessionDelegate

extension SessionManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        onPeersChanged?(session.connectedPeers)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let receivedAt = Clock.now()
        guard let message = try? decoder.decode(NetMessage.self, from: data) else { return }
        onMessage?(message, peerID, receivedAt)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser / Browser

extension SessionManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension SessionManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard !session.connectedPeers.contains(peerID) else { return }
        // Deterministic tie-break: the smaller name invites, the larger accepts.
        if myPeerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
