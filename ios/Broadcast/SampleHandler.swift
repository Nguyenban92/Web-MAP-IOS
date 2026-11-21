import UIKit
import ReplayKit
import CoreImage
import ImageIO
import WebRTC

class SampleHandler: RPBroadcastSampleHandler {
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var active = false
    private var config: BroadcastConfig?
    private var peers: [LivePeer] = []
    private var lastFrame = 0.0
    private var lastBlack = 0.0
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var startedAt = 0.0
    private var pairingBusy = false
    private var lastPairAttempt: Double = 0
    private var syncTimer: DispatchSourceTimer?
    
    private let serverURL = "https://magiao-live-map-aov.onrender.com"
    private let adminKey = "MG-FvEw0o7qt-STgTZOUbWvbNpS"
    private var hasLoggedFirstFrame = false

    private func remoteLog(_ text: String) {
        NSLog("[LiveMap] %@", text)
        guard let url = URL(string: "\(serverURL)/api/broadcast/log") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["source": "EXTENSION", "msg": text])
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    override init() {
        super.init()
        remoteLog("SampleHandler.init() called by iOS!")
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startedAt = ProcessInfo.processInfo.systemUptime
        lock.lock(); active = true; lock.unlock()
        remoteLog("broadcastStarted() launched!")
        tryAutoPair()
        startSyncTimer()
    }
    
    private func startSyncTimer() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 2.0, repeating: .seconds(3))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let isRunning = self.active
            let currentRoomID = self.config?.room.id
            self.lock.unlock()
            guard isRunning else { return }
            
            if currentRoomID == nil {
                self.tryAutoPair()
                return
            }
            
            self.checkServerAutoPair(currentRoomID: currentRoomID)
        }
        self.syncTimer = t
        t.resume()
    }

    private func isActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    private func updatePairingBusy(_ busy: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy {
            guard !pairingBusy, self.config == nil, self.active else { return false }
            pairingBusy = true
            return true
        } else {
            pairingBusy = false
            return true
        }
    }
    
    private func tryAutoPair() {
        guard !pairingBusy, config == nil, isActive() else { return }
        if let shared = SharedStore.read(), shared.enabled, shared.crop.valid {
            remoteLog("tryAutoPair() using SharedStore room: \(shared.room.id)")
            self.startWithConfig(shared)
            return
        }
        requestServerAutoPair()
    }

    private func requestServerAutoPair() {
        guard updatePairingBusy(true) else { return }

        guard let url = URL(string: "\(serverURL)/api/broadcast/auto-pair") else {
            _ = updatePairingBusy(false)
            return
        }

        remoteLog("requestServerAutoPair() fetching active room from server...")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 12
            req.setValue("Bearer \(self.adminKey)", forHTTPHeaderField: "Authorization")
            let devId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-broadcast"
            req.setValue(devId, forHTTPHeaderField: "X-Device-ID")
            if let shared = SharedStore.read(), shared.enabled {
                req.setValue(shared.room.id, forHTTPHeaderField: "X-Room-ID")
            }
            
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.remoteLog("requestServerAutoPair() response HTTP \(code)")
                _ = self.updatePairingBusy(false)
                
                guard code == 200 else { return }
                if let c = try? JSONDecoder().decode(BroadcastConfig.self, from: data), c.enabled, c.crop.valid {
                    self.remoteLog("requestServerAutoPair() auto-paired with room: \(c.room.id)")
                    self.startWithConfig(c)
                }
            } catch {
                _ = self.updatePairingBusy(false)
                self.remoteLog("requestServerAutoPair() error: \(error.localizedDescription)")
            }
        }
    }

    private func checkServerAutoPair(currentRoomID: String?) {
        guard let url = URL(string: "\(serverURL)/api/broadcast/auto-pair") else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self, self.isActive() else { return }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 8
            req.setValue("Bearer \(self.adminKey)", forHTTPHeaderField: "Authorization")
            let devId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-broadcast"
            req.setValue(devId, forHTTPHeaderField: "X-Device-ID")
            if let shared = SharedStore.read(), shared.enabled {
                req.setValue(shared.room.id, forHTTPHeaderField: "X-Room-ID")
            }
            
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let c = try? JSONDecoder().decode(BroadcastConfig.self, from: data), c.enabled, c.crop.valid else { return }
            
            if let current = currentRoomID, c.room.id != current {
                self.remoteLog("checkServerAutoPair() detected new room \(c.room.id), switching from \(current)...")
                self.switchRoom(c)
            }
        }
    }

    private func startWithConfig(_ c: BroadcastConfig) {
        lock.lock()
        defer { lock.unlock() }
        guard self.active, self.config == nil else { return }
        self.config = c
        remoteLog("startWithConfig() starting LivePeer for room: \(c.room.id)")
        let bitrate = Int(350000 + c.quality * 850000)
        
        let primarySlots = [0, 1, 2, 3, 4, 5]
        self.peers = primarySlots.map { slot in
            let peer = LivePeer(server: c.server, roomID: c.room.id, credential: c.room.publishToken, publisher: true, slot: slot, fps: Int(c.fps), maxBitrate: bitrate)
            peer.onEnded = { [weak self] in
                self?.handlePeerEnded(roomID: c.room.id)
            }
            return peer
        }
        self.peers.forEach { $0.start() }
    }

    private func switchRoom(_ c: BroadcastConfig) {
        lock.lock()
        guard self.active else { lock.unlock(); return }
        let oldPeers = self.peers
        self.peers = []
        self.config = nil
        lock.unlock()
        oldPeers.forEach { $0.stop() }
        startWithConfig(c)
    }

    private func handlePeerEnded(roomID: String) {
        lock.lock()
        guard self.active, self.config?.room.id == roomID else { lock.unlock(); return }
        self.config = nil
        let oldPeers = self.peers
        self.peers = []
        lock.unlock()
        oldPeers.forEach { $0.stop() }
        remoteLog("handlePeerEnded() room \(roomID) ended, re-pairing in 1.5s...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.tryAutoPair()
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let c = self.config
        let peers = self.peers
        let running = self.active
        let isBusy = self.pairingBusy
        lock.unlock()

        guard running else { return }

        // Continuous pairing check directly on the video frame pipeline
        if c == nil || peers.isEmpty {
            if !isBusy && (now - lastPairAttempt >= 1.5) {
                lastPairAttempt = now
                requestServerAutoPair()
            }
            return
        }

        guard let c = c else { return }

        let thermal = ProcessInfo.processInfo.thermalState
        let targetFPS = thermal == .serious || thermal == .critical ? min(15, c.fps) : c.fps
        guard now - lastFrame >= 0.9 / max(1, min(60, targetFPS)) else { return }
        lastFrame = now

        autoreleasepool {
            guard let raw = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let rawFrame = CIImage(cvPixelBuffer: raw); var frame = rawFrame
            if let a = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
               let o = CGImagePropertyOrientation(rawValue: a.uint32Value) {
                frame = rawFrame.oriented(o)
            }
            if c.crop.rotate180 ?? true { frame = frame.oriented(.down) }
            
            // Normalize landscape orientation for game play
            if frame.extent.width < frame.extent.height {
                frame = frame.oriented(.right)
            }
            let e = frame.extent
            guard e.width > 20, e.height > 20 else { return }
            
            let rawW = e.width * c.crop.width
            let rawH = e.height * c.crop.height
            let mapSide = min(rawW, rawH)
            let cropX = e.minX + e.width * c.crop.x
            let cropY = e.minY + e.height * (1.0 - c.crop.y) - mapSide
            let r = CGRect(x: cropX, y: cropY, width: mapSide, height: mapSide).integral.intersection(e)
            guard r.width > 1, r.height > 1 else { return }
            let actualSide = min(r.width, r.height)
            let targetSide: Double = c.quality >= 0.85 ? 960 : (c.quality >= 0.6 ? 640 : 384)
            let scale = min(1.0, targetSide / actualSide)
            let sidePixels = max(2, Int(actualSide * scale) / 2 * 2)
            let w = sidePixels, h = sidePixels
            guard let output = pixel(width: w, height: h) else { return }
            let squareCrop = CGRect(x: r.minX, y: r.minY, width: actualSide, height: actualSide)
            let cropped = frame.cropped(to: squareCrop)
                .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
                .transformed(by: CGAffineTransform(scaleX: Double(w) / actualSide, y: Double(h) / actualSide))
            context.render(cropped, to: output)
            if !hasLoggedFirstFrame {
                hasLoggedFirstFrame = true
                remoteLog("processSampleBuffer() 1st frame rendered and pushed! size: \(w)x\(h)")
            }
            peers.forEach { $0.push(output, timeNs: Int64(now * 1_000_000_000)) }
        }
    }

    private func pixel(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || width != poolWidth || height != poolHeight {
            pool = nil; poolWidth = width; poolHeight = height
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        guard let pool = pool else { return nil }
        var buffer: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func sendBlack(_ peer: LivePeer, now: Double) {
        guard let output = pixel(width: max(2, poolWidth), height: max(2, poolHeight)) else { return }
        context.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))), to: output)
        peer.push(output, timeNs: Int64(now * 1_000_000_000))
    }

    override func broadcastPaused() {
        lock.lock(); let p = peers; lock.unlock()
        p.forEach { sendBlack($0, now: ProcessInfo.processInfo.systemUptime) }
    }

    override func broadcastResumed() {}

    override func broadcastFinished() {
        remoteLog("broadcastFinished() called")
        syncTimer?.cancel(); syncTimer = nil
        lock.lock(); active = false; let p = peers; peers = []; config = nil; lock.unlock()
        p.forEach { $0.stop() }
        pool = nil
        context.clearCaches()
    }
}
