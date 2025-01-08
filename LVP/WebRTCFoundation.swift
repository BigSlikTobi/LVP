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
        return peerConnection?.connectionState ?? .new
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
    
    init(signalingClient: LillyTechSignalingClient, _ config: LillyTechWebRTCConfiguration) {
        self.signalingClient = signalingClient
        super.init()
        
        signalingClient.delegate = self  // Add this line
        
        let rtcConfig = config.rtcConfiguration
        let constraints = config.defaultConstraints
        
        peerConnection = peerConnectionFactory.peerConnection(
            with: rtcConfig,
            constraints: constraints,
            delegate: self
        )
        
        let audioSource = peerConnectionFactory.audioSource(with: nil)
        let audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio0")
        peerConnection?.add(audioTrack, streamIds: ["stream0"])
        
        configureAudioSession()
    }
    
    func handleSignalingPeer(_ peerId: String) {
        currentPeerId = peerId
        connect()  // Start WebRTC connection with this peer
    }
    
    func connect() {
        createOffer()
    }
    
    func disconnect() {
        // Close all peer connections
        peerConnections.values.forEach { $0.close() }
        peerConnections.removeAll()
        resetAudioSession()
    }
    
    func handleRemoteOffer(_ sdp: RTCSessionDescription) {
        peerConnection?.setRemoteDescription(sdp, completionHandler: { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
                return
            }
            self?.createAnswer()
        })
    }
    
    func handleRemoteAnswer(_ sdp: RTCSessionDescription) {
        peerConnection?.setRemoteDescription(sdp, completionHandler: { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
            }
        })
    }
    
    func handleRemoteCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate) { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func createOffer() {
        guard let pc = peerConnection, let targetPeerId = currentPeerId else { return }
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        
        pc.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self = self else { return }
            if let error = error {
                self.delegate?.webRTCService(self, didEncounterError: error)
                return
            }
            guard let sdp = sdp else {
                self.delegate?.webRTCService(self, didEncounterError: NSError(domain: "LillyTech", code: -1, userInfo: [NSLocalizedDescriptionKey: "No SDP generated"]))
                return
            }
            pc.setLocalDescription(sdp, completionHandler: { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.delegate?.webRTCService(self, didEncounterError: error)
                    return
                }
                self.delegate?.webRTCService(self, didReceiveLocalOffer: sdp)
                // Updated to use correct target
                self.signalingClient.sendOffer(sdp: sdp.sdp, target: targetPeerId)
            })
        }
    }
    
    private func createAnswer() {
        guard let pc = peerConnection, let targetPeerId = currentPeerId else { return }
        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        
        pc.answer(for: answerConstraints) { [weak self] sdp, error in
            guard let self = self else { return }
            if let error = error {
                self.delegate?.webRTCService(self, didEncounterError: error)
                return
            }
            guard let sdp = sdp else {
                self.delegate?.webRTCService(self, didEncounterError: NSError(domain: "LillyTech", code: -2, userInfo: [NSLocalizedDescriptionKey: "No SDP generated for answer"]))
                return
            }
            pc.setLocalDescription(sdp, completionHandler: { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.delegate?.webRTCService(self, didEncounterError: error)
                    return
                }
                self.delegate?.webRTCService(self, didReceiveLocalOffer: sdp)
                // Updated to use correct target
                self.signalingClient.sendAnswer(sdp: sdp.sdp, target: targetPeerId)
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
}

// MARK: - RTCPeerConnectionDelegate

extension LillyTechWebRTCServiceImpl: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        delegate?.webRTCService(self, didChangeConnectionState: state)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
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
        let sessionDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        let peerConnection = peerConnections[sender] ?? createPeerConnection(for: sender)
        
        peerConnection?.setRemoteDescription(sessionDescription) { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
                return
            }
            
            // Create answer
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveAudio": "true"],
                optionalConstraints: nil
            )
            
            peerConnection?.answer(for: constraints) { (sdp, error) in
                if let error = error {
                    self?.delegate?.webRTCService(self!, didEncounterError: error)
                    return
                }
                
                guard let sdp = sdp else { return }
                
                peerConnection?.setLocalDescription(sdp) { error in
                    if let error = error {
                        self?.delegate?.webRTCService(self!, didEncounterError: error)
                        return
                    }
                    
                    self?.signalingClient.sendAnswer(sdp: sdp.sdp, target: sender)
                }
            }
        }
    }
    
    func signalingDidReceiveAnswer(sdp: String, sender: String) {
        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnections[sender]?.setRemoteDescription(sessionDescription) { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
            }
        }
    }
    
    func signalingDidReceiveCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32, sender: String) {
        let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        peerConnections[sender]?.add(iceCandidate) { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
            }
        }
    }
    
    func signalingDidJoinRoom(peerIds: [String]) {
        // Create peer connections for all existing peers
        peerIds.forEach { peerId in
            if peerConnections[peerId] == nil {
                _ = createPeerConnection(for: peerId)
            }
        }
        
        // Clean up any old connections that are no longer needed
        let peersToRemove = Set(peerConnections.keys).subtracting(peerIds)
        peersToRemove.forEach { peerId in
            peerConnections[peerId]?.close()
            peerConnections.removeValue(forKey: peerId)
        }
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
    
    weak var delegate: LillyTechSignalingDelegate?
    private var socket: SocketIOClient?
    private var manager: SocketManager?
    
    // Add property to track peers
    private var connectedPeers: Set<String> = []
    
    // Server URL
    private let serverURL = URL(string: "http://localhost:3000")! // Replace with your server URL
    
    override init() {
        super.init()
        configureSocket()
    }
    
    private func configureSocket() {
        manager = SocketManager(socketURL: serverURL, config: [.log(true), .compress]) // Enable logging for debugging
        socket = manager?.defaultSocket
        
        // Socket event handlers
        socket?.on(clientEvent: .connect) { [weak self] data, ack in
            self?.delegate?.signalingDidConnect()
        }
        
        socket?.on(clientEvent: .disconnect) { [weak self] data, ack in
            self?.delegate?.signalingDidDisconnect()
        }
        
        socket?.on("offer") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let sdpData = data["sdp"] as? [String: String],
                  let sdp = sdpData["sdp"],
                  let sender = data["sender"] as? String else { return }
            self?.delegate?.signalingDidReceiveOffer(sdp: sdp, sender: sender)
        }
        
        socket?.on("answer") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let sdpData = data["sdp"] as? [String: String],
                  let sdp = sdpData["sdp"],
                  let sender = data["sender"] as? String else { return }
            self?.delegate?.signalingDidReceiveAnswer(sdp: sdp, sender: sender)
        }
        
        socket?.on("ice-candidate") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let candidateData = data["candidate"] as? [String: Any],
                  let candidate = candidateData["candidate"] as? String,
                  let sdpMid = candidateData["sdpMid"] as? String,
                  let sdpMLineIndex = candidateData["sdpMLineIndex"] as? Int,
                  let sender = data["sender"] as? String else { return }
            self?.delegate?.signalingDidReceiveCandidate(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: Int32(sdpMLineIndex), sender: sender)
        }
        
        socket?.on("room-joined") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let roomId = data["roomId"] as? String,
                  let peers = data["peers"] as? [String] else { return }
            
            // Update local peers list with existing peers
            self?.connectedPeers = Set(peers)
            self?.delegate?.signalingDidJoinRoom(peerIds: peers)
        }
        
        socket?.on("peer-joined") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let peerId = data["peerId"] as? String else { return }
            
            self?.handleNewPeer(peerId)
            print("Peer joined: \(peerId)")
        }
        
        socket?.on("peer-left") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let peerId = data["peerId"] as? String else { return }
            
            // Remove peer from local list
            self?.connectedPeers.remove(peerId)
            print("Peer left: \(peerId)")
        }
        
        socket?.on("error") { [weak self] data, ack in
            guard let data = data.first as? [String: Any],
                  let type = data["type"] as? String,
                  let message = data["message"] as? String else { return }
            self?.delegate?.signalingDidReceiveError(type: type, message: message)
        }
    }
    
    func connect() {
        socket?.connect()
    }
    
    func disconnect() {
        socket?.disconnect()
    }
    
    func sendJoinRoom(roomId: String) {
        let data: [String: Any] = [
            "type": "join-room",
            "roomId": roomId
            // "userId": "yourUserId"  // Optional
        ]
        socket?.emit("join-room", data)
    }
    
    func sendOffer(sdp: String, target: String) {
        let message: [String: Any] = [
            "type": "offer",
            "target": target,
            "sender": socket?.sid ?? "",
            "sdp": [
                "type": "offer",
                "sdp": sdp
            ]
        ]
        socket?.emit("offer", message)
    }
    
    func sendAnswer(sdp: String, target: String) {
        let message: [String: Any] = [
            "type": "answer",
            "target": target,
            "sender": socket?.sid ?? "",
            "sdp": [
                "type": "answer",
                "sdp": sdp
            ]
        ]
        socket?.emit("answer", message)
    }
    
    func sendIceCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32, target: String) {
        let message: [String: Any] = [
            "type": "ice-candidate",
            "target": target,
            "sender": socket?.sid ?? "",
            "candidate": [
                "candidate": candidate,
                "sdpMid": sdpMid,
                "sdpMLineIndex": sdpMLineIndex
            ]
        ]
        socket?.emit("ice-candidate", message)
    }
    
    // Add method to handle new peer connections
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
