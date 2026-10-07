import ReplayKit
import Vision
import CoreImage
import ImageIO
import WebRTC

final class SampleHandler: RPBroadcastSampleHandler {
    private let context = CIContext(options:[.cacheIntermediates:false])
    private let lock = NSLock()
    private var active = false
    private var config: BroadcastConfig?
    private var peers: [LivePeer] = []
    private var lastFrame = 0.0
    private var lastBlack = 0.0
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var session: URLSession = {
        let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=5;c.timeoutIntervalForResource=8
        return URLSession(configuration:c)
    }()
    private var startedAt = 0.0
    private var lastScan = 0.0
    private var pairingBusy = false
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startedAt = ProcessInfo.processInfo.systemUptime
        lock.lock(); active = true; lock.unlock()
    }
    private func scanPairing(_ sampleBuffer: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - startedAt < 90 else {
            finishBroadcastWithError(NSError(domain: "NBWebMap", code: 4, userInfo: [NSLocalizedDescriptionKey: "Hết thời gian ghép nối. Mở app, tạo mã khởi động mới và phát lại."]))
            return
        }
        lock.lock(); let shouldScan = !pairingBusy && now - lastScan > 0.8; lock.unlock()
        guard shouldScan, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = now
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixel, options: [:]).perform([request])
        guard let payload = request.results?.compactMap({ $0.payloadStringValue }).first(where: { $0.hasPrefix("NBWM2:https://") }),
              let url = URL(string: String(payload.dropFirst(6))), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.path == "/" || url.path.isEmpty,
              let fragment = url.fragment, fragment.hasPrefix("pair.") else { return }
        let key = String(fragment.dropFirst(5))
        guard key.count == 32 else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = nil; components.path = "/api/pair"
        var req = URLRequest(url: components.url!); req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        lock.lock(); pairingBusy = true; lock.unlock()
        session.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }; self.pairingBusy = false
            guard self.active, (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                  let c = try? JSONDecoder().decode(BroadcastConfig.self, from: data), c.enabled, c.crop.valid,
                  let server = URL(string: c.server), server.scheme == "https", server.host == url.host, server.port == url.port else { return }
            self.config = c
            let bitrate=Int(350000+c.quality*850000)
            self.peers=(0..<4).map{LivePeer(server:c.server,roomID:c.room.id,credential:c.room.publishToken,publisher:true,slot:$0,fps:Int(c.fps),maxBitrate:bitrate)}
            self.peers.forEach{$0.start()}
        }.resume()
    }

    override func processSampleBuffer(_ sampleBuffer:CMSampleBuffer,with sampleBufferType:RPSampleBufferType) {
        guard sampleBufferType == .video else{return}
        lock.lock();let c=config;let peers=self.peers;let running=active;lock.unlock()
        guard running else{return}
        guard let c=c, !peers.isEmpty else{scanPairing(sampleBuffer);return}
        let now=ProcessInfo.processInfo.systemUptime
        let thermal=ProcessInfo.processInfo.thermalState
        let targetFPS = thermal == .serious || thermal == .critical ? min(15,c.fps):c.fps
        guard now-lastFrame >= 0.9/max(1,min(60,targetFPS)) else{return}
        lastFrame=now
        autoreleasepool {
            guard let raw=CMSampleBufferGetImageBuffer(sampleBuffer) else{return}
            let rawFrame=CIImage(cvPixelBuffer:raw);var frame=rawFrame
            if let a=CMGetAttachment(sampleBuffer,key:RPVideoSampleOrientationKey as CFString,attachmentModeOut:nil) as? NSNumber,
               let o=CGImagePropertyOrientation(rawValue:a.uint32Value){let oriented=rawFrame.oriented(o);let ra=rawFrame.extent.width/rawFrame.extent.height,oa=oriented.extent.width/oriented.extent.height;if abs(oa-c.crop.referenceAspect)<abs(ra-c.crop.referenceAspect){frame=oriented}}
            // Correct the 180-degree landscape mismatch seen when the game and
            // the reference screenshot use opposite physical phone directions.
            if c.crop.rotate180 ?? true { frame = frame.oriented(.down) }
            let e=frame.extent
            // When the device leaves the selected aspect ratio, replace the remote image with black.
            guard abs(e.width/e.height-c.crop.referenceAspect)/c.crop.referenceAspect<0.04 else {
                if now-lastBlack>1 {lastBlack=now;peers.forEach{sendBlack($0,now:now)}};return
            }
            let r=CGRect(x:e.minX+e.width*c.crop.x,y:e.minY+e.height*(1-c.crop.y-c.crop.height),width:e.width*c.crop.width,height:e.height*c.crop.height).integral.intersection(e)
            guard r.width>1,r.height>1 else{return}
            let side:Double=c.quality>=0.85 ? 960 : (c.quality>=0.6 ? 640:384)
            let scale=min(1,side/max(r.width,r.height))
            let w=max(2,Int(r.width*scale)/2*2),h=max(2,Int(r.height*scale)/2*2)
            guard let output=pixel(width:w,height:h) else{return}
            let cropped=frame.cropped(to:r).transformed(by:CGAffineTransform(translationX:-r.minX,y:-r.minY)).transformed(by:CGAffineTransform(scaleX:Double(w)/r.width,y:Double(h)/r.height))
            context.render(cropped,to:output)
            peers.forEach{$0.push(output,timeNs:Int64(now*1_000_000_000))}
        }
    }
    private func pixel(width:Int,height:Int)->CVPixelBuffer? {
        if pool==nil || width != poolWidth || height != poolHeight {
            pool=nil;poolWidth=width;poolHeight=height
            let attributes:[String:Any]=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true]
            CVPixelBufferPoolCreate(kCFAllocatorDefault,nil,attributes as CFDictionary,&pool)
        }
        guard let pool=pool else{return nil}
        var buffer:CVPixelBuffer?
        let aux=[kCVPixelBufferPoolAllocationThresholdKey as String:4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,aux,&buffer)==kCVReturnSuccess else{return nil}
        return buffer
    }
    private func sendBlack(_ peer:LivePeer,now:Double) {
        guard let output=pixel(width:max(2,poolWidth),height:max(2,poolHeight)) else{return}
        context.render(CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:CVPixelBufferGetWidth(output),height:CVPixelBufferGetHeight(output))),to:output)
        peer.push(output,timeNs:Int64(now*1_000_000_000))
    }
    override func broadcastPaused() {lock.lock();let p=peers;lock.unlock();p.forEach{sendBlack($0,now:ProcessInfo.processInfo.systemUptime)}}
    override func broadcastResumed() {}
    override func broadcastFinished() {
        lock.lock();active=false;let p=peers;peers=[];config=nil;lock.unlock()
        p.forEach{$0.stop()};session.invalidateAndCancel();pool=nil;context.clearCaches()
    }
}
