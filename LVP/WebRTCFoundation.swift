import Foundation
import AVFAudio
import WebRTC

// MARK: - 1) Configuration

/// A struct for STUN-only ICE servers and constraints (audio only).
struct LillyTechWebRTCConfiguration {
    /// Provide a basic RTCConfiguration with one STUN server
    var rtcConfiguration: RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        // For a basic MVP, gather once. Later you can enable continual if needed.
        config.continualGatheringPolicy = .gatherOnce
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.tcpCandidatePolicy = .disabled
        config.keyType = .ECDSA
        config.iceTransportPolicy = .all
        return config
    }
    
    /// Constraints to receive audio only.
    var defaultConstraints: RTCMediaConstraints {
        return RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true"
            ],
            optionalConstraints: [
                "DtlsSrtpKeyAgreement": "true"  // Usually beneficial for security
            ]
        )
    }
}

// MARK: - 2) WebRTCService Protocol & Delegate

/// Delegate to observe connection state, ICE events, and errors.
protocol LillyTechWebRTCServiceDelegate: AnyObject {
    func webRTCService(_ service: LillyTechWebRTCService, didChangeConnectionState state: RTCPeerConnectionState)
    func webRTCService(_ service: LillyTechWebRTCService, didReceiveLocalOffer sdp: RTCSessionDescription)
    func webRTCService(_ service: LillyTechWebRTCService, didReceiveCandidate candidate: RTCIceCandidate)
    func webRTCService(_ service: LillyTechWebRTCService, didEncounterError error: Error)
}

/// A minimal service protocol for connecting, disconnecting, handling remote offers/answers/candidates.
protocol LillyTechWebRTCService: AnyObject {
    var delegate: LillyTechWebRTCServiceDelegate? { get set }
    var connectionState: RTCPeerConnectionState { get }
    
    func connect()                // Initiates an offer
    func disconnect()             // Closes the peer connection
    func handleRemoteOffer(_ sdp: RTCSessionDescription)
    func handleRemoteAnswer(_ sdp: RTCSessionDescription)
    func handleRemoteCandidate(_ candidate: RTCIceCandidate)
}

// MARK: - 3) WebRTCService Implementation

final class LillyTechWebRTCServiceImpl: NSObject, LillyTechWebRTCService {
    
    // Delegate for outside observers
    weak var delegate: LillyTechWebRTCServiceDelegate?
    
    // Peer connection state
    var connectionState: RTCPeerConnectionState {
        return peerConnection?.connectionState ?? .new
    }
    
    // Internal references
    private var peerConnection: RTCPeerConnection?
    private let peerConnectionFactory = RTCPeerConnectionFactory()
    private let audioSession = RTCAudioSession.sharedInstance()
    
    // Simple init that sets up the peer connection
    init(_ config: LillyTechWebRTCConfiguration) {
        super.init()
        
        let rtcConfig = config.rtcConfiguration
        let constraints = config.defaultConstraints
        
        // Create the peer connection
        peerConnection = peerConnectionFactory.peerConnection(
            with: rtcConfig,
            constraints: constraints,
            delegate: self
        )
        
        // Optionally add a local audio track if you want to capture microphone
        // For purely “listen mode,” skip this.
        let audioSource = peerConnectionFactory.audioSource(with: nil)
        let audioTrack = peerConnectionFactory.audioTrack(with: audioSource, trackId: "audio0")
        peerConnection?.add(audioTrack, streamIds: ["stream0"])
        
        // Configure iOS audio session in a minimal way for voice
        configureAudioSession()
    }
    
    // MARK: - LillyTechWebRTCService
    
    func connect() {
        // “connect” means we’re the caller → create an SDP offer
        createOffer()
    }
    
    func disconnect() {
        // Close the peer connection
        peerConnection?.close()
        resetAudioSession()
    }
    
    func handleRemoteOffer(_ sdp: RTCSessionDescription) {
        // 1. Set remote desc
        peerConnection?.setRemoteDescription(sdp, completionHandler: { [weak self] error in
            if let error = error {
                self?.delegate?.webRTCService(self!, didEncounterError: error)
                return
            }
            // 2. Since we received an offer, create an answer
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
        guard let pc = peerConnection else { return }
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
            // Set local description, then pass it to the delegate to send over signaling
            pc.setLocalDescription(sdp, completionHandler: { [weak self] error in
                if let error = error {
                    self?.delegate?.webRTCService(self!, didEncounterError: error)
                    return
                }
                self?.delegate?.webRTCService(self!, didReceiveLocalOffer: sdp)
            })
        }
    }
    
    private func createAnswer() {
        guard let pc = peerConnection else { return }
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
            // Set local description
            pc.setLocalDescription(sdp, completionHandler: { [weak self] error in
                if let error = error {
                    self?.delegate?.webRTCService(self!, didEncounterError: error)
                    return
                }
                // Typically, you’d also pass this answer back over signaling
                // to the peer that offered
                self?.delegate?.webRTCService(self!, didReceiveLocalOffer: sdp)
            })
        }
    }
    
    private func configureAudioSession() {
        // Minimal approach: capture mic & route audio to speaker
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
        // Deactivate session when done
        RTCAudioSession.sharedInstance().lockForConfiguration()
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            delegate?.webRTCService(self, didEncounterError: error)
        }
        RTCAudioSession.sharedInstance().unlockForConfiguration()
    }
}

// MARK: - RTCPeerConnectionDelegate

extension LillyTechWebRTCServiceImpl: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        delegate?.webRTCService(self, didChangeConnectionState: state)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Send out candidate to the remote peer via signaling
        delegate?.webRTCService(self, didReceiveCandidate: candidate)
    }
    
    // We’ll keep these empty or minimal for an MVP:
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // For audio-only, you might not need to do anything special here
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) { }
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }
}

// MARK: - 4) Minimal WebSocket Signaling (Optional)

/// A minimal example if you want in the same file (simplified).
protocol LillyTechSignalingDelegate: AnyObject {
    func signalingDidConnect()
    func signalingDidDisconnect()
    func signalingDidReceiveOffer(sdp: String)
    func signalingDidReceiveAnswer(sdp: String)
    func signalingDidReceiveCandidate(sdpMid: String, sdpMLineIndex: Int32, candidate: String)
}

final class LillyTechSignalingClient {
    
    weak var delegate: LillyTechSignalingDelegate?
    // Suppose you have a basic WebSocket property:
    // var webSocket: WebSocket?
    
    init() {
        // Initialize your WebSocket or other transport
    }
    
    // Connect, join a room if needed
    func connect() {
        // webSocket?.connect()
    }
    
    func disconnect() {
        // webSocket?.disconnect()
    }
    
    // Send Offer, Answer, Candidate
    func sendOffer(_ sdp: String) {
        // Build JSON or protocol message
        // webSocket?.write(string: message)
    }
    
    func sendAnswer(_ sdp: String) {
        // ...
    }
    
    func sendCandidate(mid: String, index: Int32, candidate: String) {
        // ...
    }
    
    // Handle incoming messages in didReceive(event:)
    // Then parse them, and call delegate?.signalingDidReceiveOffer(...) etc.
}