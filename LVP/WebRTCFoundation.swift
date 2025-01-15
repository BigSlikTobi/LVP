import Foundation
import AVFAudio
import WebRTC
import SocketIO

// MARK: - 1) Configuration

struct LillyTechWebRTCConfiguration {
    var rtcConfiguration: RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        config.continualGatheringPolicy = .gatherOnce
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.tcpCandidatePolicy = .disabled
        config.keyType = .ECDSA
        config.iceTransportPolicy = .all
        return config
    }
    
    var defaultConstraints: RTCMediaConstraints {
        return RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true"
            ],
            optionalConstraints: [
                "DtlsSrtpKeyAgreement": "true"
            ]
        )
    }
}

// MARK: - 2) WebRTCService Protocol & Delegate

protocol LillyTechWebRTCServiceDelegate: AnyObject {
    func webRTCService(_ service: LillyTechWebRTCService, didChangeConnectionState state: RTCPeerConnectionState)
    func webRTCService(_ service: LillyTechWebRTCService, didReceiveLocalOffer sdp: RTCSessionDescription)
    func webRTCService(_ service: LillyTechWebRTCService, didReceiveCandidate candidate: RTCIceCandidate)
    func webRTCService(_ service: LillyTechWebRTCService, didEncounterError error: Error)
    func webRTCService(_ service: LillyTechWebRTCService, didJoinRoomWithPeers peerIds: [String])
}

protocol LillyTechWebRTCService: AnyObject {
    var delegate: LillyTechWebRTCServiceDelegate? { get set }
    var connectionState: RTCPeerConnectionState { get }
    
    func connect()
    func disconnect()
    func handleRemoteOffer(_ sdp: RTCSessionDescription)
    func handleRemoteAnswer(_ sdp: RTCSessionDescription)
    func handleRemoteCandidate(_ candidate: RTCIceCandidate)
}

// MARK: - 3) WebRTCService Implementation

final class LillyTechWebRTCServiceImpl: NSObject, LillyTechWebRTCService {
    
    weak var delegate: LillyTechWebRTCServiceDelegate?
    
    var connectionState: RTCPeerConnectionState {
        guard let currentPeerId = currentPeerId,
              let currentConnection = peerConnections[currentPeerId] else {
            return .new
        }
        return currentConnection.connectionState
    }
    
    private var peerConnection: RTCPeerConnection?
    private let peerConnectionFactory = RTCPeerConnectionFactory()
    private let audioSession = RTCAudioSession.sharedInstance()
    
    // Add signaling client
    var signalingClient: LillyTechSignalingClient
    
    // Add property to track current peer
    private var currentPeerId: String?
    
    // Add this property to track all connected peers and their connections
    private var peerConnections: [String: RTCPeerConnection] = [:]
    
    // Add property to track if we're the host
    private var isHost: Bool = false
    
    // Add this property after other private properties
    private var connectedPeers: Set<String> = []
    
    init(signalingClient: LillyTechSignalingClient, _ config: LillyTechWebRTCConfiguration, isHost: Bool = false) {
        self.signalingClient = signalingClient
        self.isHost = isHost
        super.init()
        
        signalingClient.delegate = self
        
        // Remove the peerConnection initialization that was here
        // The connections will be created on demand when peers join
        
        configureAudioSession()
    }
    
    func handleSignalingPeer(_ peerId: String) {
        print("handleSignalingPeer called with peerId: \(peerId)")
        currentPeerId = peerId
        // Create a new peer connection for this peer
        let connection = createPeerConnection(for: peerId)
        
        // If we're the host, initiate the offer
        if isHost {
            createOffer(for: peerId)
        }
    }

    func connect() {
        // The offer will be created when peer-joined is received
    }
    
    func disconnect() {
        // Close all peer connections
        peerConnections.values.forEach { $0.close() }
        peerConnections.removeAll()
        resetAudioSession()
    }
    
    func handleRemoteOffer(_ sdp: RTCSessionDescription) {
        print("handleRemoteOffer called with sdp: \(sdp.sdp) and current peer ID: \(String(describing: currentPeerId))")
        
        guard let currentPeerId = currentPeerId else {
            delegate?.webRTCService(self, didEncounterError: NSError(domain: "LillyTech", code: -1, userInfo: [NSLocalizedDescriptionKey: "No current peer ID"]))
            return
        }
        
        // Get existing connection or create new one
        let peerConnection = peerConnections[currentPeerId] ?? createPeerConnection(for: currentPeerId)
        
        guard let pc = peerConnection else {
            delegate?.webRTCService(self, didEncounterError: NSError(domain: "LillyTech", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create peer connection"]))
            return
        }
        
        pc.setRemoteDescription(sdp) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.delegate?.webRTCService(self, didEncounterError: error)
                return
            }
            self.createAnswer(for: currentPeerId)
        }
    }

    
    func handleRemoteAnswer(_ sdp: RTCSessionDescription) {
        print("handleRemoteAnswer called with sdp: \(sdp.sdp) and current peer ID: \(String(describing: currentPeerId))")
        
        guard let currentPeerId = currentPeerId else {
            delegate?.webRTCService(self, didEncounterError: NSError(domain: "LillyTech", code: -1, userInfo: [NSLocalizedDescriptionKey: "No current peer ID"]))
            return
        }
        
        guard let peerConnection = peerConnections[currentPeerId] else {
            delegate?.webRTCService(self, didEncounterError: NSError(domain: "LillyTech", code: -1, userInfo: [NSLocalizedDescriptionKey: "No peer connection found for current peer"]))
            return
        }
        
        peerConnection.setRemoteDescription(sdp) { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
            }
        }
    }

    
    func handleRemoteCandidate(_ candidate: RTCIceCandidate) {
        print("handleRemoteCandidate called with candidate: \(candidate.sdp), sdpMid: \(candidate.sdpMid ?? ""), sdpMLineIndex: \(candidate.sdpMLineIndex), and current peer ID: \(String(describing: currentPeerId))")
        
        guard let currentPeerId = currentPeerId else {
            delegate?.webRTCService(self, didEncounterError: NSError(domain: "LillyTech", code: -1, userInfo: [NSLocalizedDescriptionKey: "No current peer ID"]))
            return
        }
        
        guard let peerConnection = peerConnections[currentPeerId] else {
            delegate?.webRTCService(self, didEncounterError: NSError(domain: "LillyTech", code: -1, userInfo: [NSLocalizedDescriptionKey: "No peer connection found for current peer"]))
            return
        }
        
        peerConnection.add(candidate) { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
            }
        }
    }

    
    // MARK: - Private Helpers
    
    private func createOffer(for peerId: String) {
        print("createOffer called for peerId: \(peerId)")
        print("Creating local offer for peerId: \(peerId)")
        
        guard let peerConnection = peerConnections[peerId] else {
            delegate?.webRTCService(self, didEncounterError: NSError(
                domain: "LillyTech",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No peer connection found for peer: \(peerId)"]
            ))
            return
        }
        
        currentPeerId = peerId
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        
        print("Creating local offer for peerId: \(peerId) using peer connection: \(peerConnection)")
        
        peerConnection.offer(for: offerConstraints) { [weak self] sdp, error in
            print("offer generated for peerId: \(peerId)")
            guard let self = self else { return }
            if let error = error {
                self.delegate?.webRTCService(self, didEncounterError: error)
                return
            }
            guard let sdp = sdp else {
                self.delegate?.webRTCService(self, didEncounterError: NSError(
                    domain: "LillyTech",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No SDP generated"]
                ))
                return
            }
            
            print("Local offer created, sending to peer: \(peerId)")
            print("setting local description for offer for peerId: \(peerId) with sdp: \(sdp.sdp)")
            peerConnection.setLocalDescription(sdp, completionHandler: { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.delegate?.webRTCService(self, didEncounterError: error)
                    return
                }
                print("Local description set for offer, now sending to peer: \(peerId)")
                print("Local description set for offer for peerId: \(peerId), now sending to signaling client")
                self.delegate?.webRTCService(self, didReceiveLocalOffer: sdp)
                self.signalingClient.sendOffer(sdp: sdp.sdp, target: peerId)
            })
        }
    }

    
    private func createAnswer(for peerId: String) {
        print("createAnswer called for peerId: \(peerId)")
        print("Creating local answer for peer: \(peerId)")
        
        guard let peerConnection = peerConnections[peerId] else {
            delegate?.webRTCService(self, didEncounterError: NSError(
                domain: "LillyTech",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No peer connection found for peer: \(peerId)"]
            ))
            return
        }
        
        currentPeerId = peerId
        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        
        print("Creating local answer for peerId: \(peerId) using peer connection: \(peerConnection)")
        
        peerConnection.answer(for: answerConstraints) { [weak self] sdp, error in
            print("answer generated for peerId: \(peerId)")
            guard let self = self else { return }
            if let error = error {
                self.delegate?.webRTCService(self, didEncounterError: error)
                return
            }
            guard let sdp = sdp else {
                self.delegate?.webRTCService(self, didEncounterError: NSError(
                    domain: "LillyTech",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No SDP generated for answer"]
                ))
                return
            }
            
            print("Local answer created, sending to peer: \(peerId)")
            print("setting local description for answer for peerId: \(peerId) with sdp: \(sdp.sdp)")
            peerConnection.setLocalDescription(sdp, completionHandler: { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.delegate?.webRTCService(self, didEncounterError: error)
                    return
                }
                print("Local description set for answer, now sending to peer: \(peerId)")
                self.delegate?.webRTCService(self, didReceiveLocalOffer: sdp)
                self.signalingClient.sendAnswer(sdp: sdp.sdp, target: peerId)
            })
        }
    }

    
    private func configureAudioSession() {
        RTCAudioSession.sharedInstance().lockForConfiguration()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            delegate?.webRTCService(self, didEncounterError: error)
        }
        RTCAudioSession.sharedInstance().unlockForConfiguration()
    }
    
    private func resetAudioSession() {
        RTCAudioSession.sharedInstance().lockForConfiguration()
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            delegate?.webRTCService(self, didEncounterError: error)
        }
        RTCAudioSession.sharedInstance().unlockForConfiguration()
    }
    
    private func createPeerConnection(for peerId: String) -> RTCPeerConnection? {
        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        
        let connection = peerConnectionFactory.peerConnection(
            with: rtcConfig,
            constraints: constraints,
            delegate: self
        )
        
        if let connection = connection {
            let audioSource = peerConnectionFactory.audioSource(with: nil)
            let audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio0")
            connection.add(audioTrack, streamIds: ["stream0"])
            peerConnections[peerId] = connection
        }
        
        return connection
    }
    
    // Add method to handle peer join and initiate connection if we're the host
    private func handlePeerJoined(_ peerId: String) {
        print("handlePeerJoined called with peerId: \(peerId)")
        if isHost {
            createOffer(for: peerId)  // Use the new method signature
        }
    }
    
    // Update the handleNewPeer method
    func handleNewPeer(_ peerId: String) {
        print("handleNewPeer called with peerId: \(peerId) and isHost: \(isHost)")
        print("handleNewPeer called with peerId: \(peerId)")
        
        // Create new connection if one doesn't exist
        if peerConnections[peerId] == nil {
            print("Creating new peer connection for: \(peerId)")
            _ = createPeerConnection(for: peerId)
        }
        
        currentPeerId = peerId
        connectedPeers.insert(peerId)
        handlePeerJoined(peerId)
        
        print("Peer joined, isHost=\(isHost) -> \(isHost ? "Creating offer" : "Waiting for offer")")
    }
}

// MARK: - RTCPeerConnectionDelegate

extension LillyTechWebRTCServiceImpl: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        delegate?.webRTCService(self, didChangeConnectionState: state)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("didGenerate candidate: \(candidate.sdp)")
        guard let targetPeerId = currentPeerId else { return }
        delegate?.webRTCService(self, didReceiveCandidate: candidate)
        signalingClient.sendIceCandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid ?? "",
            sdpMLineIndex: candidate.sdpMLineIndex,
            target: targetPeerId
        )
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) { }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }
}

// Add this extension after the RTCPeerConnectionDelegate extension
extension LillyTechWebRTCServiceImpl: LillyTechSignalingDelegate {
    func signalingDidConnect() {
        print("Signaling connected")
    }
    
    func signalingDidDisconnect() {
        print("Signaling disconnected")
    }
    
    func signalingDidReceiveOffer(sdp: String, sender: String) {
        print("Received offer from \(sender)")
        let sessionDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        currentPeerId = sender  // Set the current peer ID
        
        peerConnection?.setRemoteDescription(sessionDescription) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.delegate?.webRTCService(self, didEncounterError: error)
                return
            }
            print("Remote description set, creating answer")
            self.createAnswer(for: sender)  // This will automatically send the answer via socket
        }
    }
    
    func signalingDidReceiveAnswer(sdp: String, sender: String) {
        print("Received answer from \(sender). Setting remote description.")
        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnections[sender]?.setRemoteDescription(sessionDescription) { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
            }
        }
    }
    
    func signalingDidReceiveCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32, sender: String) {
        print("Received ICE candidate from \(sender). sdpMid=\(sdpMid), sdpMLineIndex=\(sdpMLineIndex)")
        let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        peerConnections[sender]?.add(iceCandidate) { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
            }
        }
    }
    
    func signalingDidJoinRoom(peerIds: [String]) {
        print("Joined room with peers: \(peerIds)")
        if isHost {
            // If we're the host, create offers for each peer
            peerIds.forEach { peerId in
                print("Creating offer for peer: \(peerId)")
                createOffer(for: peerId)
            }
        }
        // Update to use the correct delegate method
        delegate?.webRTCService(self, didJoinRoomWithPeers: peerIds)
    }
    
    func signalingDidReceiveError(type: String, message: String) {
        let error = NSError(domain: "LillyTech.Signaling",
                           code: -1,
                           userInfo: [
                            NSLocalizedDescriptionKey: message,
                            "type": type
                           ])
        delegate?.webRTCService(self, didEncounterError: error)
    }
}

extension String {
    static func generateRandomRoomId(length: Int = 4) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }
}

// MARK: - 4) WebSocket Signaling with Socket.IO

protocol LillyTechSignalingDelegate: AnyObject {
    func signalingDidConnect()
    func signalingDidDisconnect()
    func signalingDidReceiveOffer(sdp: String, sender: String)
    func signalingDidReceiveAnswer(sdp: String, sender: String)
    func signalingDidReceiveCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32, sender: String)
    func signalingDidJoinRoom(peerIds: [String])
    func signalingDidReceiveError(type: String, message: String)
}

final class LillyTechSignalingClient: NSObject {
    static let shared = LillyTechSignalingClient()  // Added singleton

    // Mark initializer as private
    private override init() {
        // Store strong references to Socket.IO components
        self.manager = SocketManager(socketURL: serverURL, config: [.log(true), .compress])
        self.socket = manager.defaultSocket
        super.init()
        configureSocket()
    }
    
    weak var delegate: LillyTechSignalingDelegate?
    
    // Store strong references to Socket.IO components
    private let manager: SocketManager
    private let socket: SocketIOClient
    private var connectedPeers: Set<String> = []
    private let serverURL = URL(string: "https://80.187.65.196:3000")! // Replace with your server URL
    private var targetPeerId: String?
    
    private func configureSocket() {
        // Update socket references to use the class property
        socket.on(clientEvent: .connect) { [weak self] data, ack in
            self?.delegate?.signalingDidConnect()
        }
        
        socket.on(clientEvent: .disconnect) { [weak self] data, ack in
            self?.delegate?.signalingDidDisconnect()
        }
        
        socket.on("offer") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let sdpData = data["sdp"] as? [String: String],
                  let sdp = sdpData["sdp"],
                  let sender = data["sender"] as? String else { return }
            self?.delegate?.signalingDidReceiveOffer(sdp: sdp, sender: sender)
        }
        
        socket.on("answer") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let sdpData = data["sdp"] as? [String: String],
                  let sdp = sdpData["sdp"],
                  let sender = data["sender"] as? String else { return }
            self?.delegate?.signalingDidReceiveAnswer(sdp: sdp, sender: sender)
        }
        
        socket.on("ice-candidate") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let candidateData = data["candidate"] as? [String: Any],
                  let candidate = candidateData["candidate"] as? String,
                  let sdpMid = candidateData["sdpMid"] as? String,
                  let sdpMLineIndex = candidateData["sdpMLineIndex"] as? Int,
                  let sender = data["sender"] as? String else { return }
            self?.delegate?.signalingDidReceiveCandidate(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: Int32(sdpMLineIndex), sender: sender)
        }
        
        socket.on("room-joined") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let roomId = data["roomId"] as? String,
                  let peers = data["peers"] as? [String] else { return }
            
            // If there's exactly one peer, set it as the target
            if peers.count == 1 {
                self?.targetPeerId = peers[0]
            }
            
            // Update local peers list with existing peers
            self?.connectedPeers = Set(peers)
            self?.delegate?.signalingDidJoinRoom(peerIds: peers)
        }
        
        socket.on("peer-joined") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let peerId = data["peerId"] as? String else { return }
            
            self?.handleNewPeer(peerId)
            print("Peer joined: \(peerId)")
        }
        
        socket.on("peer-left") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let peerId = data["peerId"] as? String else { return }
            
            // Remove peer from local list
            self?.connectedPeers.remove(peerId)
            print("Peer left: \(peerId)")
        }
        
        socket.on("error") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let type = data["type"] as? String,
                  let message = data["message"] as? String else { return }
            self?.delegate?.signalingDidReceiveError(type: type, message: message)
        }
    }
    
    func connect() {
        socket.connect()
    }
    
    func disconnect() {
        socket.disconnect()
    }
    
    func sendJoinRoom(roomId: String) {
        let data: [String: Any] = [
            "type": "join-room",
            "roomId": roomId
            // "userId": "yourUserId"  // Optional
        ]
        socket.emit("join-room", data)
    }
    
    func sendOffer(sdp: String, target: String) {
        let message: [String: Any] = [
            "type": "offer",
            "target": target,
            "sender": socket.sid ?? "",
            "sdp": [
                "type": "offer",
                "sdp": sdp
            ]
        ]
        socket.emit("offer", message)
    }
    
    func sendAnswer(sdp: String, target: String) {
        let message: [String: Any] = [
            "type": "answer",
            "target": target,
            "sender": socket.sid ?? "",
            "sdp": [
                "type": "answer",
                "sdp": sdp
            ]
        ]
        socket.emit("answer", message)
    }
    
    func sendIceCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32, target: String) {
        let message: [String: Any] = [
            "type": "ice-candidate",
            "target": target,
            "sender": socket.sid ?? "",
            "candidate": [
                "candidate": candidate,
                "sdpMid": sdpMid,
                "sdpMLineIndex": sdpMLineIndex
            ]
        ]
        socket.emit("ice-candidate", message)
    }
    
    // Add method to set target peer explicitly
    func setTargetPeer(_ peerId: String) {
        targetPeerId = peerId
    }
    
    // Update method to handle new peer connections
    // Only triggers handleSignalingPeer if delegate is LillyTechWebRTCServiceImpl
    func handleNewPeer(_ peerId: String) {
        connectedPeers.insert(peerId)
        if let webRTCService = delegate as? LillyTechWebRTCServiceImpl {
            webRTCService.handleSignalingPeer(peerId)
        }
    }
    
    // Add helper method to get connected peers
    func getConnectedPeers() -> [String] {
        return Array(connectedPeers)
    }
}
