import Foundation
import WebRTC

enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
    case failed
    
    var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .failed: return "Connection Failed"
        }
    }
}

class RTCViewModel: ObservableObject {
    @Published var roomId: String = ""
    @Published var inputRoomId: String = ""  // Add this line
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var remotePeerIds: [String] = []
    @Published var errorMessage: String?
    @Published var isHost: Bool = false //
    
    private var webRTCService: LillyTechWebRTCService?
    private var signalingClient: LillyTechSignalingClient?
    
    func initialize() {
        signalingClient = LillyTechSignalingClient.shared  // Updated here
        webRTCService = LillyTechWebRTCServiceImpl(
            signalingClient: signalingClient!,
            LillyTechWebRTCConfiguration(),
            isHost: isHost  // Pass the isHost flag
        )
        
        webRTCService?.delegate = self
        signalingClient?.delegate = self
    }
    
    func handleConnectionAction() {
        guard let webRTCService = webRTCService,
              let signalingClient = signalingClient else {
            errorMessage = "Services not initialized"
            return
        }
        
        if connectionStatus == .disconnected {
            joinRoom()
        } else {
            leaveRoom()
        }
    }
    
    func createRoom() {
        guard let signalingClient = signalingClient else {
            errorMessage = "Services not initialized"
            return
        }
        
        isHost = true
        initialize()  // Reinitialize with isHost = true
        roomId = String.generateRandomRoomId()
        signalingClient.connect()
    }

    func joinRoom() {
        guard let signalingClient = signalingClient else {
            errorMessage = "Services not initialized"
            return
        }
        
        isHost = false
        initialize()  // Reinitialize with isHost = false
        roomId = inputRoomId
        signalingClient.connect()
    }
    
    func leaveRoom() {
        webRTCService?.disconnect()
        signalingClient?.disconnect()
        connectionStatus = .disconnected
        remotePeerIds = []
    }
}

// MARK: - WebRTC Delegate
extension RTCViewModel: LillyTechWebRTCServiceDelegate {
    func webRTCService(_ service: LillyTechWebRTCService, didChangeConnectionState state: RTCPeerConnectionState) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .connected:
                self?.connectionStatus = .connected
            case .failed, .disconnected:
                self?.connectionStatus = .failed
            case .connecting:
                self?.connectionStatus = .connecting
            default:
                break
            }
        }
    }
    
    func webRTCService(_ service: LillyTechWebRTCService, didReceiveLocalOffer sdp: RTCSessionDescription) {
        // Handle local offer if needed
    }
    
    func webRTCService(_ service: LillyTechWebRTCService, didReceiveCandidate candidate: RTCIceCandidate) {
        // Handle ICE candidate if needed
    }
    
    func webRTCService(_ service: LillyTechWebRTCService, didEncounterError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = error.localizedDescription
            self?.connectionStatus = .failed
        }
    }
    
    func webRTCService(_ service: LillyTechWebRTCService, didJoinRoomWithPeers peerIds: [String]) {
        DispatchQueue.main.async { [weak self] in
            self?.remotePeerIds = peerIds
        }
    }
}

// MARK: - Signaling Delegate
extension RTCViewModel: LillyTechSignalingDelegate {
    func signalingDidConnect() {
        guard let signalingClient = signalingClient,
              let webRTCService = webRTCService else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = .connecting
        }
        
        // First join the room
        signalingClient.sendJoinRoom(roomId: roomId)
        // Then initialize WebRTC connection
        webRTCService.connect()
    }
    
    func signalingDidDisconnect() {
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = .disconnected
            self?.remotePeerIds = []
        }
    }
    
    func signalingDidReceiveOffer(sdp: String, sender: String) {
        // No UI update needed, handled by WebRTCService
    }
    
    func signalingDidReceiveAnswer(sdp: String, sender: String) {
        // No UI update needed, handled by WebRTCService
    }
    
    func signalingDidReceiveCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32, sender: String) {
        // No UI update needed, handled by WebRTCService
    }
    
    func signalingDidJoinRoom(peerIds: [String]) {
        DispatchQueue.main.async { [weak self] in
            self?.remotePeerIds = peerIds
        }
    }
    
    func signalingDidReceiveError(type: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = "\(type): \(message)"
            self?.connectionStatus = .failed
        }
    }
}
