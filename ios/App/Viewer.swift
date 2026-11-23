import SwiftUI
import AVKit
import WebRTC
import CoreImage

final class MapSurface:UIView {
    override class var layerClass:AnyClass{AVSampleBufferDisplayLayer.self}
    var display:AVSampleBufferDisplayLayer{layer as! AVSampleBufferDisplayLayer}
}
final class LivePiPViewController:AVPictureInPictureVideoCallViewController {
    let videoSurface=MapSurface()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoSurface.translatesAutoresizingMaskIntoConstraints=false
        videoSurface.display.videoGravity = .resizeAspectFill
        view.addSubview(videoSurface)
        NSLayoutConstraint.activate([
            videoSurface.leadingAnchor.constraint(equalTo:view.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            videoSurface.topAnchor.constraint(equalTo:view.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo:view.bottomAnchor)
        ])
        preferredContentSize=CGSize(width:220,height:220)
    }
}
struct MapPreview:UIViewRepresentable {
    let engine:ViewerEngine
    func makeUIView(context:Context)->MapSurface{engine.surface}
    func updateUIView(_ view:MapSurface,context:Context){}
}
// Decode callback -> latest frame only -> PiP display. Never accumulate a render backlog.
final class PiPFrameSink:NSObject,RTCVideoRenderer {
    var onFrame:((CVPixelBuffer)->Void)?
    private let lock=NSLock()
    private var pending=false
    func setSize(_ size:CGSize){}
    func renderFrame(_ frame:RTCVideoFrame?) {
        guard let frame=frame else{return}
        lock.lock();if pending{lock.unlock();return};pending=true;lock.unlock()
        guard let pixel=Self.pixel(frame.buffer) else{lock.lock();pending=false;lock.unlock();return}
        DispatchQueue.main.async { [weak self] in
            guard let self=self else{return}
            self.onFrame?(pixel)
            self.lock.lock();self.pending=false;self.lock.unlock()
        }
    }
    private static func pixel(_ buffer:RTCVideoFrameBuffer)->CVPixelBuffer? {
        if let native=buffer as? RTCCVPixelBuffer {return native.pixelBuffer}
        // VP8 fallback, or a decoder providing I420: copy Y and interleave U/V into NV12.
        let yuv=buffer.toI420(),w=Int(buffer.width),h=Int(buffer.height)
        guard w>0,h>0,w<=1920,h<=1920 else{return nil}
        var pixel:CVPixelBuffer?
        let attrs=[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,attrs,&pixel)==kCVReturnSuccess,let pixel=pixel else{return nil}
        CVPixelBufferLockBaseAddress(pixel,[]);defer{CVPixelBufferUnlockBaseAddress(pixel,[])}
        guard let y=CVPixelBufferGetBaseAddressOfPlane(pixel,0),let uv=CVPixelBufferGetBaseAddressOfPlane(pixel,1) else{return nil}
        let sy=CVPixelBufferGetBytesPerRowOfPlane(pixel,0),suv=CVPixelBufferGetBytesPerRowOfPlane(pixel,1)
        for row in 0..<h {memcpy(y.advanced(by:row*sy),yuv.dataY.advanced(by:row*Int(yuv.strideY)),w)}
        for row in 0..<Int(yuv.chromaHeight) {
            let dest=uv.advanced(by:row*suv).assumingMemoryBound(to:UInt8.self)
            let u=yuv.dataU.advanced(by:row*Int(yuv.strideU)),v=yuv.dataV.advanced(by:row*Int(yuv.strideV))
            for col in 0..<Int(yuv.chromaWidth) {dest[col*2]=u[col];dest[col*2+1]=v[col]}
        }
        return pixel
    }
}
@MainActor
final class ViewerEngine:NSObject,ObservableObject,AVPictureInPictureControllerDelegate {
    @Published var message="Dán link do máy phát chia sẻ."
    @Published var stats="Chưa có dữ liệu đường truyền"
    @Published var connected=false
    @Published var hasFrame=false
    @Published var paused=false
    @Published var pipActive=false
    let surface=MapSurface()
    private let pipViewController=LivePiPViewController()
    private let sink=PiPFrameSink()
    private var pip:AVPictureInPictureController?
    private var peer:LivePeer?
    private var track:RTCVideoTrack?
    private var connectionID=UUID()
    private var lastFrame=Date.distantPast
    private var timer:Timer?
    private var leaveURL:URL?
    private var accessToken=""
    private let imageContext=CIContext(options:[.cacheIntermediates:false])
    override init() {
        super.init();surface.display.videoGravity = .resizeAspect
        Self.configureTimebase(surface.display)
        pipViewController.loadViewIfNeeded()
        Self.configureTimebase(pipViewController.videoSurface.display)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            // A screen-share is a live call-style source, not seekable media.
            // This content source gives iOS the live PiP chrome (close/restore)
            // instead of the media-player chrome that contains +/-10 seconds.
            pip=AVPictureInPictureController(contentSource:.init(activeVideoCallSourceView:surface,contentViewController:pipViewController))
            pip?.delegate=self
        }
        sink.onFrame = { [weak self] pixel in
            guard let self=self,self.connected,!self.paused else{return}
            self.enqueue(pixel);self.lastFrame=Date();self.hasFrame=true
        }
    }
    private static func configureTimebase(_ layer:AVSampleBufferDisplayLayer) {
        var timebase:CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator:kCFAllocatorDefault,sourceClock:CMClockGetHostTimeClock(),timebaseOut:&timebase)
        if let t=timebase {layer.controlTimebase=t;CMTimebaseSetTime(t,time:CMClockGetTime(CMClockGetHostTimeClock()));CMTimebaseSetRate(t,rate:1)}
    }
    func connect(link:String,password:String,forceRelay:Bool=false) async {
        stop();let attempt=connectionID
        guard let url=URL(string:link.trimmingCharacters(in:.whitespacesAndNewlines)),url.scheme=="https",url.host != nil,url.user==nil,url.password==nil,let fragment=url.fragment else{message="Cần link HTTPS đầy đủ từ người phát.";return}
        let parts=fragment.split(separator:".")
        guard parts.count==2,parts[0].count==12,parts[1].count==32,parts[0].allSatisfy({"0123456789ABCDEF".contains($0)}) else{message="Link phòng không hợp lệ.";return}
        var base=URLComponents(url:url,resolvingAgainstBaseURL:false)!
        base.fragment=nil;base.query=nil;base.path=""
        let origin=base.url!.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        base.path="/api/rooms/\(parts[0])/access"
        var req=URLRequest(url:base.url!);req.httpMethod="POST";req.timeoutInterval=10
        req.setValue("Bearer \(parts[1])",forHTTPHeaderField:"Authorization");req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.httpBody=try? JSONSerialization.data(withJSONObject:["password":password]);message="Đang kiểm tra phòng…"
        do {
            let (data,response)=try await URLSession.shared.data(for:req)
            guard attempt==connectionID else{return}
            let code=(response as? HTTPURLResponse)?.statusCode
            guard code==200,let result=try JSONSerialization.jsonObject(with:data) as? [String:String],let token=result["token"] else{message=code==403 ? "Sai mật khẩu phòng.":"Không vào được phòng (HTTP \(code ?? 0)).";return}
            try AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback,options:[.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            connected=true;accessToken=token;base.path="/api/rooms/\(parts[0])/rtc";leaveURL=base.url
            let p=LivePeer(server:origin,roomID:String(parts[0]),credential:token,publisher:false,forceRelay:forceRelay)
            p.onStatus = { [weak self] text in DispatchQueue.main.async{guard let self=self,self.connectionID==attempt else{return};self.message=text} }
            p.onStats = { [weak self] text in DispatchQueue.main.async{guard let self=self,self.connectionID==attempt else{return};self.stats=text} }
            p.onEnded = { [weak self] in DispatchQueue.main.async{guard let self=self,self.connectionID==attempt else{return};self.stop();self.message="Phiên đã kết thúc. Kiểm tra mạng hoặc xin link mới."} }
            p.onTrack = { [weak self] track in DispatchQueue.main.async {
                guard let self=self,self.connectionID==attempt else{return}
                self.track?.remove(self.sink);self.track=track;track.add(self.sink)
            } }
            peer=p;p.start()
            timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){ [weak self] _ in
                guard let self=self,self.connected else{return}
                if Date().timeIntervalSince(self.lastFrame)>3 {self.blank()}
            }
        }catch{if attempt==connectionID{message=error.localizedDescription}}
    }
    private func enqueue(_ pixel:CVPixelBuffer) {
        var format:CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescriptionOut:&format)==noErr,let format=format else{return}
        var timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMClockGetTime(CMClockGetHostTimeClock()),decodeTimeStamp:.invalid)
        var sample:CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescription:format,sampleTiming:&timing,sampleBufferOut:&sample)==noErr,let sample=sample else{return}
        for display in [surface.display,pipViewController.videoSurface.display] {
            if display.status == .failed{display.flush()}
            if display.isReadyForMoreMediaData{display.enqueue(sample)}
        }
    }
    private func blank() {
        hasFrame=false;surface.display.flushAndRemoveImage();pipViewController.videoSurface.display.flushAndRemoveImage()
        var buffer:CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,240,240,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&buffer)==kCVReturnSuccess,let buffer=buffer else{return}
        imageContext.render(CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:240,height:240)),to:buffer);enqueue(buffer)
    }
    func startPiP() {
        guard hasFrame,let pip=pip else{message="Đợi có hình trước khi bật PiP.";return}
        guard pip.isPictureInPicturePossible else{message="iOS chưa sẵn sàng PiP. Đợi có hình rồi thử lại.";return}
        pip.startPictureInPicture()
    }
    func stop() {
        connectionID=UUID();connected=false;paused=false;peer?.stop();peer=nil
        track?.remove(sink);track=nil;timer?.invalidate();timer=nil
        if let url=leaveURL,!accessToken.isEmpty {
            var r=URLRequest(url:url);r.httpMethod="POST";r.timeoutInterval=3
            r.setValue("Bearer \(accessToken)",forHTTPHeaderField:"Authorization");r.setValue("application/json",forHTTPHeaderField:"Content-Type")
            r.httpBody=Data("{\"op\":\"leave\"}".utf8);URLSession.shared.dataTask(with:r).resume()
        }
        leaveURL=nil;accessToken="";pip?.stopPictureInPicture();blank();stats="Chưa có dữ liệu đường truyền"
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
    func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,failedToStartPictureInPictureWithError error:Error){message="PiP: "+error.localizedDescription}
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){pipActive=true}
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){pipActive=false}
    func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:@escaping(Bool)->Void){completionHandler(true)}
}
struct ViewerView:View {
    @StateObject private var engine=ViewerEngine()
    @State private var link=""
    @State private var password=""
    @State private var forceRelay=false
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:18) {
                    // Header Brand
                    HStack {
                        VStack(alignment:.leading,spacing:2) {
                            Text("MA GIÁO")
                                .font(.system(size:32,weight:.black,design:.rounded))
                                .foregroundStyle(LinearGradient(colors:[Studio.gold,Color(red:1,green:0.91,blue:0.58)],startPoint:.topLeading,endPoint:.bottomTrailing))
                            Text("LIVE MAP AOV")
                                .font(.system(size:11,weight:.bold,design:.rounded))
                                .tracking(3)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        HStack(spacing:6) {
                            Circle().fill(engine.connected ? Color.green : Studio.aqua).frame(width:8,height:8)
                            Text(engine.connected ? "Đang xem":"Sẵn sàng").font(.caption.bold()).foregroundStyle(.white)
                        }
                        .padding(.horizontal,12).padding(.vertical,6)
                        .background(Color.white.opacity(0.08),in:Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15),lineWidth:1))
                    }
                    .padding(.top,4)

                    // Card Kết nối
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            Label("KẾT NỐI PHÒNG",systemImage:"link")
                                .font(.caption.bold())
                                .foregroundStyle(Studio.gold)
                            Spacer()
                            if !link.isEmpty {
                                Button("Xóa") { link = "" }
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack {
                            TextField("Dán link phòng...", text:$link)
                                .font(.subheadline)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button {
                                if let clip = UIPasteboard.general.string {
                                    link = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.subheadline)
                                    .foregroundStyle(Studio.aqua)
                            }
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))

                        SecureField("Mật khẩu (nếu có)", text:$password)
                            .font(.subheadline)
                            .padding(12)
                            .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))

                        HStack(spacing: 10) {
                            Button {
                                Task { await engine.connect(link:link,password:password,forceRelay:forceRelay) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.fill")
                                    Text("VÀO XEM")
                                        .font(.system(size: 16, weight: .black, design: .rounded))
                                }
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(
                                    LinearGradient(colors: [Studio.gold, Color(red: 1, green: 0.84, blue: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                                .shadow(color: Studio.gold.opacity(0.3), radius: 6, y: 2)
                            }
                            .disabled(engine.connected)
                            .opacity(engine.connected ? 0.5 : 1.0)

                            if engine.connected {
                                Button(role: .destructive) {
                                    engine.stop()
                                } label: {
                                    Text("DỪNG")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.red)
                                        .frame(width: 80, height: 48)
                                        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.3), lineWidth: 1))
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))

                    // Khung xem trước hình vuông 1:1
                    VStack(spacing: 8) {
                        MapPreview(engine:engine)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 260)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius:16))
                            .overlay(RoundedRectangle(cornerRadius:16).stroke(Studio.aqua.opacity(0.4), lineWidth: 1))
                            .shadow(color: Studio.aqua.opacity(0.2), radius: 10)

                        HStack {
                            Circle()
                                .fill(engine.hasFrame ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(engine.message)
                                .font(.caption.bold())
                                .foregroundStyle(engine.hasFrame ? Color.green : Studio.aqua)
                        }
                        if !engine.stats.isEmpty {
                            Text(engine.stats)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Nút MỞ CỬA SỔ SIÊU NHỎ 1:1
                    Button {
                        engine.startPiP()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "pip.enter")
                                .font(.title3)
                            Text(engine.pipActive ? "CỬA SỔ ĐANG MỞ" : "MỞ CỬA SỔ SIÊU NHỎ (1:1)")
                                .font(.system(size: 16, weight: .black, design: .rounded))
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            LinearGradient(colors: [Studio.aqua, Color(red: 0.4, green: 0.85, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .shadow(color: Studio.aqua.opacity(0.35), radius: 8, y: 3)
                    }
                    .disabled(!engine.hasFrame || engine.pipActive)
                    .opacity(!engine.hasFrame || engine.pipActive ? 0.5 : 1.0)

                    // Hero Art
                    HeroBannerView()
                }
                .padding()
            }
            .background(LinearGradient(colors:[Studio.background,Color(red:0.01,green:0.08,blue:0.14),Studio.background],startPoint:.topLeading,endPoint:.bottomTrailing).ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear {
                if link.isEmpty, let clip = UIPasteboard.general.string, clip.contains("https://"), clip.contains("#") {
                    link = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }
}
