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
        videoSurface.display.videoGravity = .resizeAspect
        view.addSubview(videoSurface)
        NSLayoutConstraint.activate([
            videoSurface.leadingAnchor.constraint(equalTo:view.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            videoSurface.topAnchor.constraint(equalTo:view.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo:view.bottomAnchor)
        ])
        // A wide live canvas lets the system offer a much shorter compact PiP
        // than the old square media-player window. The square map stays fitted.
        preferredContentSize=CGSize(width:320,height:180)
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
        guard CVPixelBufferCreate(kCFAllocatorDefault,320,240,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&buffer)==kCVReturnSuccess,let buffer=buffer else{return}
        imageContext.render(CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:320,height:240)),to:buffer);enqueue(buffer)
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
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:2) {
                        Text("THOVE-NB").font(.system(size:34,weight:.black,design:.rounded)).foregroundStyle(LinearGradient(colors:[Studio.gold,.yellow.opacity(0.8)],startPoint:.topLeading,endPoint:.bottomTrailing))
                        Text("LIVE MAP NGUYỄN BÂN").font(.system(size:12,weight:.semibold,design:.rounded)).tracking(3).foregroundStyle(.white.opacity(0.78))
                    }
                    HStack { Label("XEM TRỰC TIẾP",systemImage:"play.rectangle.fill").font(.headline).foregroundStyle(Studio.aqua); Spacer(); Text(engine.connected ? "ĐANG KẾT NỐI":"CHỜ KẾT NỐI").font(.caption2.bold()).foregroundStyle(engine.connected ? .green:.secondary).padding(.horizontal,10).padding(.vertical,6).background(.black.opacity(0.3),in:Capsule()) }
                    Text("Nhận vùng bản đồ và mở cửa sổ siêu gọn khi chơi game.").foregroundStyle(.secondary)
                    GroupBox("Kết nối phòng") {
                        VStack(spacing:12) {
                            HStack { TextField("Dán link xem HTTPS",text:$link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled(); Button("Dán"){link=UIPasteboard.general.string ?? link} }
                            SecureField("Mật khẩu phòng (nếu có)",text:$password)
                            HStack {
                                Button("Kết nối"){Task{await engine.connect(link:link,password:password,forceRelay:forceRelay)}}.buttonStyle(.borderedProminent).disabled(engine.connected)
                                Button("Dừng xem",role:.destructive){engine.stop()}.buttonStyle(.bordered).disabled(!engine.connected)
                            }
                        }.padding(.top,8)
                    }.groupBoxStyle(StudioGroupBoxStyle())
                    MapPreview(engine:engine).frame(height:300).background(.black).clipShape(RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(Studio.aqua.opacity(0.55)))
                    Label(engine.message,systemImage:engine.hasFrame ? "checkmark.circle.fill":"antenna.radiowaves.left.and.right").font(.callout).foregroundStyle(Studio.aqua)
                    Text(engine.stats).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
                    Button{engine.startPiP()}label:{Label(engine.pipActive ? "PiP ĐANG MỞ":"MỞ CỬA SỔ SIÊU GỌN",systemImage:"pip.enter").font(.headline).frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).tint(Studio.aqua).foregroundStyle(.black).controlSize(.large).disabled(!engine.hasFrame||engine.pipActive)
                    DisclosureGroup("Kết nối nâng cao") {
                        Toggle("Chỉ dùng TURN",isOn:$forceRelay).disabled(engine.connected)
                        Text("Mặc định dùng P2P, tự thử TURN nếu máy chủ đã cấu hình. Chỉ bật ép TURN khi có dịch vụ chuyển tiếp. RTT là thời gian mạng khứ hồi, không phải độ trễ toàn bộ hình ảnh.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack { Text("Tối đa 4 người xem • Nguyễn Bân").font(.caption).foregroundStyle(.secondary); Spacer(); Link("Zalo",destination:URL(string:"https://zalo.me/0779977792")!).font(.caption.bold()) }
                }.textFieldStyle(.roundedBorder).padding()
            }.background(LinearGradient(colors:[Studio.background,Color(red:0.01,green:0.08,blue:0.14),Studio.background],startPoint:.topLeading,endPoint:.bottomTrailing).ignoresSafeArea()).navigationTitle("Xem / PiP")
        }
    }
}
