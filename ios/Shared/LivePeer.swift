import Foundation
import WebRTC
import CoreVideo

struct ICEEntry: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}
struct SignalCandidate: Codable {
    let sdp: String
    let sdpMLineIndex: Int32
    let sdpMid: String?
}
struct SignalState: Decodable {
    let epoch: Int
    let viewer: Bool
    let publisherOnline: Bool
    let offer: String?
    let answer: String?
    let candidates: [SignalCandidate]
    let iceServers: [ICEEntry]
    let relayAvailable: Bool
}
// A single serial queue owns all peer and negotiation state. Media has a one-frame queue.
final class LivePeer: NSObject, RTCPeerConnectionDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        if let h264 = encoder.supportedCodecs().first(where: { $0.name == "H264" }) { encoder.preferredCodec = h264 }
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    let publisher: Bool
    var onStatus: ((String) -> Void)?
    var onTrack: ((RTCVideoTrack) -> Void)?
    var onEnded: (() -> Void)?
    var onStats: ((String) -> Void)?
    private let queue = DispatchQueue(label: "nb.live.peer", qos: .userInitiated)
    private let mediaLock = NSLock()
    private var mediaPending = false
    private var pc: RTCPeerConnection?
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var track: RTCVideoTrack?
    private var sender: RTCRtpSender?
    private let endpoint: URL
    private let credential: String
    private let fps: Int
    private let maxBitrate: Int
    private let session: URLSession
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var epoch = -1
    private var remoteReady = false
    private var negotiating = false
    private var candidateIndex = 0
    private var pollBusy = false
    private var initialOperation: String?
    private var signalSuccess = Date()
    private var stateStarted = Date()
    private var lastReset = Date.distantPast
    private var lastStats = Date.distantPast
    private var badSince: Date?
    private var relayAvailable = false
    private var operations: [[String: Any]] = []
    private var posting = false
    private var forceRelay: Bool
    init(server: String, roomID: String, credential: String, publisher: Bool, fps: Int = 30, maxBitrate: Int = 1200000, forceRelay: Bool = false) {
        self.endpoint = URL(string: "\(server)/api/rooms/\(roomID)/rtc")!
        self.credential = credential; self.publisher = publisher; self.fps = fps; self.maxBitrate = maxBitrate; self.forceRelay = forceRelay
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
        self.session = URLSession(configuration: config)
        super.init()
    }
    func start() {
        queue.async {
            guard self.timer == nil, !self.stopped else { return }
            self.initialOperation = self.publisher ? "reset" : "join"
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .seconds(1))
            t.setEventHandler { [weak self] in self?.tick() }; self.timer = t; t.resume()
        }
    }
    private func report(_ text: String) { onStatus?(text) }
    private func request(_ payload: [String: Any]?, completion: @escaping (Int, Data?) -> Void) {
        var r = URLRequest(url: endpoint); r.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if let payload = payload { r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: payload); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        session.dataTask(with: r) { [weak self] data, response, _ in
            guard let self = self else { return }
            self.queue.async { if !self.stopped { completion((response as? HTTPURLResponse)?.statusCode ?? 0, data) } }
        }.resume()
    }
    private func tick() {
        guard !stopped else { return }
        if Date().timeIntervalSince(signalSuccess)>15 {
            // Fail closed: a dead signaling service must not keep a revoked room streaming forever.
            report("Mất máy chủ quá 15 giây — dừng phiên. Kết nối lại khi có mạng."); shutdown(); onEnded?(); return
        }
        flushOperations()
        guard !pollBusy else { return }; pollBusy = true
        let op = initialOperation
        request(op.map { ["op":$0] }) { [weak self] code, data in
            guard let self = self else { return }; self.pollBusy = false
            if code == 401 || code == 404 { self.report("Phòng đã đóng hoặc quyền kết nối hết hạn."); self.shutdown(); self.onEnded?(); return }
            guard code == 200, let data = data, let state = try? JSONDecoder().decode(SignalState.self, from: data) else {
                if code == 409 && !self.publisher { self.initialOperation = "join"; self.report("Phòng đang có người xem, hoặc đang ghép nối lại.") }
                else { self.report("Đang nối lại máy chủ…") }; return
            }
            self.initialOperation = nil; self.signalSuccess = Date(); self.relayAvailable = state.relayAvailable
            self.apply(state)
            if Date().timeIntervalSince(self.lastStats)>2 { self.lastStats=Date(); self.readStats() }
            if self.publisher, state.viewer, let peer = self.pc {
                let broken = peer.iceConnectionState == .failed || peer.iceConnectionState == .disconnected
                let waitingTooLong = peer.iceConnectionState != .connected && peer.iceConnectionState != .completed && Date().timeIntervalSince(self.stateStarted)>25
                if broken || waitingTooLong {
                    if self.badSince == nil { self.badSince=Date() }
                    if Date().timeIntervalSince(self.badSince!)>5 && Date().timeIntervalSince(self.lastReset)>15 {
                        self.lastReset=Date();self.badSince=nil;self.initialOperation="reset"
                        self.report(state.relayAvailable ? "Đang thương lượng lại đường truyền…" : "P2P chưa kết nối. Mạng này có thể cần TURN; chưa có máy chủ chuyển tiếp.")
                    }
                } else { self.badSince=nil }
            }
        }
    }
    private func send(_ payload: [String: Any]) {
        guard operations.count < 100 else { report("Quá nhiều tín hiệu; hãy kết nối lại."); return }
        operations.append(payload); flushOperations()
    }
    private func flushOperations() {
        guard !posting, !operations.isEmpty, !stopped else { return }
        posting=true
        let first=operations[0]
        request(first) { [weak self] code, _ in
            guard let self=self else{return};self.posting=false
            // The generation may have changed while the request was running.
            if let old=first["epoch"] as? Int, old != self.epoch { self.flushOperations();return }
            if code==200 || code==409 || code==400 || code==403 || code==429 {
                if !self.operations.isEmpty {self.operations.removeFirst()}
                if code != 200 {self.report("Đang đồng bộ phiên (HTTP \(code))")}
            }
            if code==401 || code==404 {self.shutdown();self.onEnded?();return}
            // Retry transient errors on the next timer tick, not in a tight loop.
            if code==200 {self.flushOperations()}
        }
    }
    private func apply(_ state: SignalState) {
        if state.epoch != epoch {
            pc?.delegate=nil;pc?.close();pc=nil;source=nil;capturer=nil;track=nil;sender=nil
            epoch=state.epoch;remoteReady=false;negotiating=false;candidateIndex=0;operations=[]
            stateStarted=Date()
            if state.viewer { buildPeer(state.iceServers) }
        }
        guard state.viewer else { report("Đã ghép nối • Chờ người xem mở link");return }
        guard let pc=pc else {return}
        if publisher {
            if pc.localDescription == nil && !negotiating { makeLocalDescription(offer:true,peer:pc) }
            if let answer=state.answer, !remoteReady, !negotiating { setRemote(answer,type:.answer,peer:pc) }
        } else if let offer=state.offer, !remoteReady, !negotiating { setRemote(offer,type:.offer,peer:pc) }
        if remoteReady {
            while candidateIndex<state.candidates.count {
                let c=state.candidates[candidateIndex];candidateIndex+=1
                pc.add(RTCIceCandidate(sdp:c.sdp,sdpMLineIndex:c.sdpMLineIndex,sdpMid:c.sdpMid)) { _ in }
            }
        }
    }
    private func buildPeer(_ entries: [ICEEntry]) {
        let config=RTCConfiguration();config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually;config.bundlePolicy = .maxBundle
        config.iceTransportPolicy = forceRelay ? .relay : .all
        config.iceServers=entries.map { RTCIceServer(urlStrings:$0.urls,username:$0.username,credential:$0.credential) }
        let constraints=RTCMediaConstraints(mandatoryConstraints:nil,optionalConstraints:nil)
        guard let peer=Self.factory.peerConnection(with:config,constraints:constraints,delegate:self) else {report("Không tạo được WebRTC.");return}
        pc=peer
        if publisher {
            let src=Self.factory.videoSource(forScreenCast:true);source=src
            capturer=RTCVideoCapturer(delegate:src)
            let video=Self.factory.videoTrack(with:src,trackId:"nb-map-video");track=video
            sender=peer.add(video,streamIds:["nb-map"])
            tuneSender()
        }
        report("Đang kết nối video trực tiếp…")
    }
    private func tuneSender() {
        guard let sender=sender else{return}
        let p=sender.parameters
        for e in p.encodings {e.maxBitrateBps=NSNumber(value:maxBitrate);e.maxFramerate=NSNumber(value:fps)}
        sender.parameters=p
    }
    private func makeLocalDescription(offer:Bool,peer:RTCPeerConnection) {
        negotiating=true
        let constraints=RTCMediaConstraints(mandatoryConstraints:["OfferToReceiveAudio":"false","OfferToReceiveVideo":publisher ? "false":"true"],optionalConstraints:nil)
        let callback: (RTCSessionDescription?, Error?) -> Void = { [weak self, weak peer] sdp,error in
            guard let self=self,let peer=peer else{return}
            self.queue.async {
                guard self.pc === peer,!self.stopped else{return}
                guard error==nil,let sdp=sdp else{self.negotiating=false;self.report("Không tạo được mô tả video.");return}
                peer.setLocalDescription(sdp) { [weak self,weak peer] error in
                    guard let self=self,let peer=peer else{return}
                    self.queue.async {
                        guard self.pc === peer,!self.stopped else{return};self.negotiating=false
                        guard error==nil else{self.report("Lỗi thiết lập video cục bộ.");return}
                        self.tuneSender()
                        self.send(["op":offer ? "offer":"answer","epoch":self.epoch,"sdp":sdp.sdp])
                    }
                }
            }
        }
        if offer {peer.offer(for:constraints,completionHandler:callback)}else{peer.answer(for:constraints,completionHandler:callback)}
    }
    private func setRemote(_ sdp:String,type:RTCSdpType,peer:RTCPeerConnection) {
        negotiating=true
        peer.setRemoteDescription(RTCSessionDescription(type:type,sdp:sdp)) { [weak self,weak peer] error in
            guard let self=self,let peer=peer else{return}
            self.queue.async {
                guard self.pc === peer,!self.stopped else{return};self.negotiating=false
                guard error==nil else{self.report("Lỗi thương lượng video từ máy bên kia.");return}
                self.remoteReady=true
                if !self.publisher {
                    if let track=peer.receivers.compactMap({$0.track as? RTCVideoTrack}).first {self.onTrack?(track)}
                    self.makeLocalDescription(offer:false,peer:peer)
                }
            }
        }
    }
    func push(_ buffer:CVPixelBuffer,timeNs:Int64) {
        mediaLock.lock();if mediaPending{mediaLock.unlock();return};mediaPending=true;mediaLock.unlock()
        queue.async {
            defer{self.mediaLock.lock();self.mediaPending=false;self.mediaLock.unlock()}
            guard !self.stopped,let source=self.source,let cap=self.capturer else{return}
            source.capturer(cap,didCapture:RTCVideoFrame(buffer:RTCCVPixelBuffer(pixelBuffer:buffer),rotation:._0,timeStampNs:timeNs))
        }
    }
    private func readStats() {
        guard let peer=pc else{return}
        peer.statistics { [weak self,weak peer] report in
            guard let self=self,let peer=peer else{return}
            self.queue.async {
                guard self.pc === peer,!self.stopped else{return}
                let list=report.statistics.values
                let media=list.first{ $0.type == (self.publisher ? "outbound-rtp":"inbound-rtp") && ($0.values["kind"] as? String == "video" || $0.values["mediaType"] as? String == "video") }
                let fps=(media?.values["framesPerSecond"] as? NSNumber)?.intValue ?? 0
                let pair=list.first{$0.type=="candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue==true && $0.values["state"] as? String == "succeeded"}
                let rtt=(pair?.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
                let candidateID=pair?.values["localCandidateId"] as? String
                let remoteID=pair?.values["remoteCandidateId"] as? String
                let relay=[candidateID,remoteID].compactMap{$0}.contains{ report.statistics[$0]?.values["candidateType"] as? String == "relay" }
                let delay=rtt.map{String(Int($0*1000))+" ms RTT"} ?? "RTT —"
                self.onStats?("\(fps) fps • \(delay) • \(relay ? "TURN":"P2P")")
            }
        }
    }
    func stop() {queue.async{self.shutdown()}}
    private func shutdown() {
        guard !stopped else{return};stopped=true
        timer?.cancel();timer=nil;pc?.delegate=nil;pc?.close();pc=nil;operations=[]
        source=nil;track=nil;capturer=nil;sender=nil;session.invalidateAndCancel()
    }
    func peerConnection(_ peerConnection:RTCPeerConnection,didChange stateChanged:RTCSignalingState) {}
    func peerConnection(_ peerConnection:RTCPeerConnection,didAdd stream:RTCMediaStream) {}
    func peerConnection(_ peerConnection:RTCPeerConnection,didRemove stream:RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection:RTCPeerConnection) {}
    func peerConnection(_ peerConnection:RTCPeerConnection,didChange newState:RTCIceConnectionState) {
        queue.async {
            guard self.pc === peerConnection,!self.stopped else{return}
            if newState == .connected || newState == .completed {self.report("Video trực tiếp đã kết nối");self.badSince=nil}
            else if newState == .failed {self.report(self.relayAvailable ? "Mất kết nối, đang khôi phục…":"Không xuyên được mạng. Cần TURN hoặc đổi mạng.")}
            else if newState == .disconnected {self.report("Đường truyền gián đoạn, đang khôi phục…")}
        }
    }
    func peerConnection(_ peerConnection:RTCPeerConnection,didChange newState:RTCIceGatheringState) {}
    func peerConnection(_ peerConnection:RTCPeerConnection,didGenerate candidate:RTCIceCandidate) {
        queue.async {
            guard self.pc === peerConnection,!self.stopped else{return}
            self.send(["op":"candidate","epoch":self.epoch,"candidate":["sdp":candidate.sdp,"sdpMLineIndex":candidate.sdpMLineIndex,"sdpMid":candidate.sdpMid as Any? ?? NSNull()]])
        }
    }
    func peerConnection(_ peerConnection:RTCPeerConnection,didRemove candidates:[RTCIceCandidate]) {}
    func peerConnection(_ peerConnection:RTCPeerConnection,didOpen dataChannel:RTCDataChannel) {}
}
