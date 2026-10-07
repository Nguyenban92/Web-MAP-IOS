import SwiftUI
import PhotosUI
import ReplayKit
import CoreImage.CIFilterBuiltins

@main
struct NBWebMapApp: App {
    var body: some Scene { WindowGroup { RootView().preferredColorScheme(.dark) } }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var server = UserDefaults.standard.string(forKey: "server") ?? ""
    @Published var adminKey = ""
    @Published var password = ""
    @Published var crop = Crop()
    @Published var screenshot: UIImage?
    @Published var room: Room?
    @Published var fps: Double = 30
    @Published var quality: Double = 0.7
    @Published var message = "Chọn ảnh chụp màn hình game để căn vùng bản đồ."
    @Published var working = false
    @Published var status = "Chưa phát"
    init() {
        if let data = UserDefaults.standard.data(forKey: "crop"), let saved = try? JSONDecoder().decode(Crop.self, from: data) { crop = saved }
        if let c = SharedStore.read(), c.enabled { room = c.room; server = c.server; crop = c.crop; fps = c.fps >= 60 ? 60 : (c.fps >= 30 ? 30 : 15); quality = c.quality }
    }
    @Published var pairing = ""
    func preparePairing() async {
        guard let room = room else { return }
        working = true; defer { working = false }
        do {
            try save()
            let config = BroadcastConfig(server: server, room: room, crop: crop, fps: fps, quality: quality, enabled: true)
            var req = URLRequest(url: URL(string: "\(server)/api/rooms/\(room.id)/pair")!)
            req.httpMethod = "POST"; req.timeoutInterval = 10
            req.setValue("Bearer \(room.publishToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(config)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 201,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: String], let url = value["pairURL"] else { throw failure("Không tạo được mã khởi động. Kiểm tra máy chủ v3.") }
            pairing = "NBWM2:" + url
        } catch { message = error.localizedDescription }
    }
    private var refreshing = false
    func refreshStatus() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        guard let room = room, let url = URL(string: "\(server)/api/rooms/\(room.id)/status") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        req.setValue("Bearer \(room.publishToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200,
              let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let viewers=v["viewers"] as? Int ?? 0, live=v["liveViewers"] as? Int ?? 0
        status = live>0 ? "Đang phát trực tiếp • \(live)/4 người xem" : ((v["paired"] as? Bool == true) ? "Đã ghép nối • Đang chờ người xem (\(viewers)/4)" : "Chờ bật THOVE-NB Broadcast")
    }
    func save() throws {
        guard crop.valid else { throw failure("Vùng chọn không hợp lệ") }
        UserDefaults.standard.set(server, forKey: "server")
        UserDefaults.standard.set(try JSONEncoder().encode(crop), forKey: "crop")
        if let room = room { try SharedStore.save(BroadcastConfig(server: server, room: room, crop: crop, fps: fps, quality: quality, enabled: true)) }
    }
    func failure(_ text: String) -> NSError { NSError(domain: "NBWebMap", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func createRoom() async {
        working = true; defer { working = false }
        do {

            guard room == nil else { throw failure("Đóng phòng cũ trước khi tạo phòng mới.") }
            server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            while server.hasSuffix("/") { server.removeLast() }
            guard let url = URL(string: server), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { throw failure("Nhập địa chỉ gốc HTTPS của máy chủ, ví dụ https://map.example.com") }
            guard screenshot != nil else { throw failure("Chọn ảnh màn hình game để xác định vùng trước.") }
            guard !adminKey.isEmpty else { throw failure("Nhập khóa tạo phòng đã đặt trên máy chủ.") }
            var request = URLRequest(url: url.appendingPathComponent("api/rooms"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw failure("Không tạo được phòng. Kiểm tra máy chủ và khóa tạo phòng.") }
            room = try JSONDecoder().decode(Room.self, from: data)
            try save()
            message = "Phòng đã sẵn sàng. Bấm Chuẩn bị, bật Broadcast và chờ ghép nối trước khi vào game."
        } catch { message = error.localizedDescription }
    }
    func closeRoom() async {
        guard let r = room else { return }
        working = true; defer { working = false }
        if var c = SharedStore.read() { c.enabled = false; try? SharedStore.save(c) }
        do {
            guard let url = URL(string: "\(server)/api/rooms/\(r.id)") else { throw failure("Địa chỉ không hợp lệ") }
            var req = URLRequest(url: url); req.httpMethod = "DELETE"; req.timeoutInterval = 10
            req.setValue("Bearer \(r.publishToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode
            guard code == 204 || code == 404 else { throw failure("Máy chủ chưa xác nhận đóng phòng") }
            room = nil; pairing = ""; message = "Đã đóng phòng và vô hiệu hóa link."
        } catch {
            message = "Chưa đóng được phòng. Dừng phát bằng nút ghi màn hình iOS, rồi thử Đóng phòng lại khi có mạng."
        }
    }
    func load(_ item: PhotosPickerItem?) async {
        guard let item = item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size = image.size
        let factor = min(1, 1600 / max(size.width, size.height))
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        let normalized = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        screenshot = normalized
        crop.referenceAspect = Double(target.width / target.height)
        if let bytes = normalized.jpegData(compressionQuality: 0.8) { try? bytes.write(to: previewURL, options: .atomic) }
        message = "Kéo khung xanh để di chuyển; kéo chấm góc dưới phải để đổi kích thước."
    }
    var previewURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("preview.jpg") }
    func restorePreview() { if screenshot == nil { screenshot = UIImage(contentsOfFile: previewURL.path) } }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var photo: PhotosPickerItem?
    @State private var showQR = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:2) {
                            Text("THOVE-NB").font(.system(size:34,weight:.black,design:.rounded))
                                .foregroundStyle(LinearGradient(colors:[Studio.gold,Color(red:1,green:0.91,blue:0.58)],startPoint:.topLeading,endPoint:.bottomTrailing))
                            Text("LIVE MAP NGUYỄN BÂN").font(.system(size:12,weight:.semibold,design:.rounded)).tracking(3).foregroundStyle(.white.opacity(0.78))
                        }
                        Spacer()
                        Label(model.server.isEmpty ? "Chưa kết nối":"Đã kết nối",systemImage:"circle.fill")
                            .font(.caption.bold()).foregroundStyle(model.server.isEmpty ? .secondary:Studio.aqua)
                            .padding(.horizontal,12).padding(.vertical,8)
                            .background(.black.opacity(0.25),in:Capsule()).overlay(Capsule().stroke((model.server.isEmpty ? Color.gray:Studio.aqua).opacity(0.5)))
                    }
                    HStack(spacing:14) {
                        ZStack { Circle().fill(Studio.aqua.opacity(0.12)); Circle().stroke(Studio.aqua.opacity(0.45),lineWidth:2); Image(systemName:"dot.radiowaves.left.and.right").font(.title).foregroundStyle(Studio.aqua) }.frame(width:68,height:68)
                        VStack(alignment:.leading,spacing:5) {
                            Text(model.room == nil ? "Sẵn sàng thiết lập":"Sẵn sàng phát").font(.headline)
                            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if model.room != nil {
                            Button { Task { await model.preparePairing() } } label:{ Label("BẮT ĐẦU PHÁT",systemImage:"antenna.radiowaves.left.and.right").font(.caption.bold()).padding(.vertical,8) }
                                .buttonStyle(.borderedProminent).tint(Studio.aqua).foregroundStyle(.black).disabled(model.working)
                        }
                    }.padding(16).studioCard(accent:Studio.aqua)
                    HStack {
                        StudioStep(number:"01",title:"Máy chủ",active:!model.server.isEmpty)
                        Rectangle().fill(Studio.aqua.opacity(0.35)).frame(height:1)
                        StudioStep(number:"02",title:"Vùng chia sẻ",active:model.screenshot != nil)
                        Rectangle().fill(.white.opacity(0.18)).frame(height:1)
                        StudioStep(number:"03",title:"Phòng phát",active:model.room != nil)
                    }
                    GroupBox("1. Máy chủ") {
                        VStack(spacing: 12) {
                            HStack { TextField("https://map.example.com", text: $model.server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(model.room != nil); Button("Dán"){model.server=UIPasteboard.general.string ?? model.server}.disabled(model.room != nil) }
                            HStack { SecureField("Khóa tạo phòng (ADMIN_KEY)", text: $model.adminKey); Button("Dán"){model.adminKey=UIPasteboard.general.string ?? model.adminKey} }
                            SecureField("Mật khẩu người xem (tùy chọn)", text: $model.password)
                        }.textFieldStyle(.roundedBorder).padding(.top, 8)
                    }.groupBoxStyle(StudioGroupBoxStyle())
                    GroupBox("2. Chọn vùng bản đồ") {
                        VStack(alignment: .leading, spacing: 12) {
                            PhotosPicker(selection: $photo, matching: .images) { Label("Chọn ảnh màn hình game", systemImage: "photo") }
                            if let image = model.screenshot {
                                CropEditor(image: image, crop: $model.crop)
                                Text("Ảnh mẫu chỉ lưu trên iPhone. Chỉ phần đã cắt được đưa vào luồng video.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Góc trái") { model.crop.x = 0.01; model.crop.y = 0.02; model.crop.width = min(model.crop.width, 0.99); model.crop.height = min(model.crop.height, 0.98) }
                                Spacer()
                                Button("Góc phải") { model.crop.x = max(0, 0.99 - model.crop.width); model.crop.y = 0.02; model.crop.height = min(model.crop.height, 0.98) }
                            }
                            Toggle("Đảo hướng phát 180°", isOn: Binding(
                                get: { model.crop.rotate180 ?? true },
                                set: { model.crop.rotate180 = $0 }
                            ))
                            Text("Bật nếu vùng phát nằm ở góc đối diện vùng đã chọn. Với iPhone này nên để bật.").font(.caption).foregroundStyle(.secondary)
                            HStack { Text("Khung/giây"); Spacer(); Text("\(Int(model.fps)) fps") }
                            Picker("FPS mục tiêu", selection: $model.fps) { Text("15").tag(15.0); Text("30").tag(30.0); Text("60").tag(60.0) }.pickerStyle(.segmented)
                            HStack { Text("Chất lượng"); Spacer(); Text("\(Int(model.quality * 100))%") }
                            Picker("Chất lượng", selection: $model.quality) { Text("Nhẹ").tag(0.4); Text("Cân bằng").tag(0.7); Text("Nét").tag(0.9) }.pickerStyle(.segmented)
                            Text("Mặc định 30 fps. 60 fps là mục tiêu; tốc độ thực tế phụ thuộc máy, mạng và nhiệt độ.").font(.caption).foregroundStyle(.secondary)
                            Button("Lưu vùng và chất lượng") {
                                do { try model.save(); model.message = "Đã lưu. Nếu đang phát, dừng Broadcast rồi tạo mã khởi động mới để áp dụng." } catch { model.message = error.localizedDescription }
                            }
                        }.padding(.top, 8)
                    }.groupBoxStyle(StudioGroupBoxStyle())
                    GroupBox("3. Phòng phát") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let room = model.room, let url = URL(string: room.viewerURL) {
                                Text("Mã phòng: \(room.id)").font(.headline).textSelection(.enabled)
                                HStack {
                                    ShareLink(item: url) { Label("Gửi link", systemImage: "square.and.arrow.up") }
                                    Spacer()
                                    Button("QR") { showQR = true }
                                }
                                Button("Chuẩn bị / Bắt đầu phát") { Task { await model.preparePairing() } }.buttonStyle(.borderedProminent).disabled(model.working)
                                if !model.pairing.isEmpty {
                                    PairingPanel(value: model.pairing, status: model.status)
                                }
                                Text(model.status).foregroundStyle(.mint)
                                Button("Đóng phòng và vô hiệu hóa link", role: .destructive) { Task { await model.closeRoom() } }.disabled(model.working)
                            } else {
                                Button(model.working ? "Đang tạo…" : "Tạo phòng") { Task { await model.createRoom() } }
                                    .buttonStyle(.borderedProminent).disabled(model.working)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.groupBoxStyle(StudioGroupBoxStyle())
                    Text(model.message).font(.callout).foregroundStyle(.orange)
                    HStack { Text("Thông tin: Nguyễn Bân").font(.caption).foregroundStyle(.secondary); Spacer(); Link(destination:URL(string:"https://zalo.me/0779977792")!){Label("Liên hệ Zalo",systemImage:"message.fill").font(.caption.bold())} }
                    Text("Giữ game cùng chiều với ảnh mẫu. Tắt thông báo trước khi phát: mọi nội dung xuất hiện trong vùng chọn đều có thể được truyền. Video WebRTC ưu tiên H.264, không truyền âm thanh.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.background(LinearGradient(colors:[Studio.background,Color(red:0.01,green:0.08,blue:0.14),Studio.background],startPoint:.topLeading,endPoint:.bottomTrailing).ignoresSafeArea())
                .onAppear { model.restorePreview() }
                .onChange(of: photo) { item in Task { await model.load(item) } }
                .onReceive(timer) { _ in Task { await model.refreshStatus() } }
                .sheet(isPresented: $showQR) { if let room = model.room { QRSheet(value: room.viewerURL) } }
        }
    }
}

enum Studio {
    static let background=Color(red:0.015,green:0.035,blue:0.065)
    static let panel=Color(red:0.055,green:0.085,blue:0.125)
    static let aqua=Color(red:0.08,green:0.92,blue:0.96)
    static let gold=Color(red:0.95,green:0.72,blue:0.30)
}
struct StudioCardModifier:ViewModifier {
    let accent:Color
    func body(content:Content)->some View { content.background(LinearGradient(colors:[Studio.panel.opacity(0.98),Studio.background.opacity(0.94)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).stroke(LinearGradient(colors:[accent.opacity(0.72),.white.opacity(0.08)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1)).shadow(color:accent.opacity(0.10),radius:14,y:6) }
}
extension View { func studioCard(accent:Color=Studio.gold)->some View { modifier(StudioCardModifier(accent:accent)) } }
struct StudioGroupBoxStyle:GroupBoxStyle {
    func makeBody(configuration:Configuration)->some View {
        VStack(alignment:.leading,spacing:12) { configuration.label.font(.headline.bold()).foregroundStyle(Studio.gold); configuration.content }
            .padding(16).studioCard()
    }
}
struct StudioStep:View {
    let number:String,title:String,active:Bool
    var body:some View { VStack(spacing:5) { Text(number).font(.caption.bold()).foregroundStyle(active ? .black:.secondary).frame(width:34,height:34).background(active ? Studio.aqua:Color.white.opacity(0.08),in:Circle()).overlay(Circle().stroke(active ? Studio.aqua:Color.white.opacity(0.18))); Text(title).font(.caption2).foregroundStyle(active ? Studio.aqua:.secondary).lineLimit(1) }.frame(maxWidth:.infinity) }
}

struct CropEditor: View {
    let image: UIImage
    @Binding var crop: Crop
    @State private var origin: Crop?
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: w, height: h)
                Rectangle().fill(Color.mint.opacity(0.18)).overlay(Rectangle().stroke(Color.mint, lineWidth: 2))
                    .frame(width: w * crop.width, height: h * crop.height)
                    .offset(x: w * crop.x, y: h * crop.y)
                    .gesture(DragGesture().onChanged { v in
                        if origin == nil { origin = crop }
                        guard let start = origin else { return }
                        crop.x = min(max(0, start.x + v.translation.width / w), 1 - crop.width)
                        crop.y = min(max(0, start.y + v.translation.height / h), 1 - crop.height)
                    }.onEnded { _ in origin = nil })
                Circle().fill(Color.mint).frame(width: 28, height: 28)
                    .offset(x: w * (crop.x + crop.width) - 14, y: h * (crop.y + crop.height) - 14)
                    .gesture(DragGesture().onChanged { v in
                        if origin == nil { origin = crop }
                        guard let start = origin else { return }
                        crop.width = min(max(0.04, start.width + v.translation.width / w), 1 - crop.x)
                        crop.height = min(max(0.04, start.height + v.translation.height / h), 1 - crop.y)
                    }.onEnded { _ in origin = nil })
            }.clipped()
        }.aspectRatio(image.size.width / image.size.height, contentMode: .fit)
    }
}
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 55, height: 55))
        view.preferredExtension = (Bundle.main.bundleIdentifier ?? "vn.nguyenban.nbwebmap") + ".Broadcast"
        view.showsMicrophoneButton = false
        return view
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
struct QRSheet: View {
    let value: String
    var body: some View {
        VStack(spacing: 20) {
            Text("Quét để xem bản đồ").font(.title2.bold())
            if let image = qrImage() { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 260, height: 260).padding().background(.white) }
            Text("Link có chứa quyền xem. Chỉ gửi cho người bạn muốn chia sẻ.").multilineTextAlignment(.center).padding()
        }
    }
    func qrImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let out = filter.outputImage, let cg = CIContext().createCGImage(out.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: out.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ContentView().tabItem { Label("Phát", systemImage: "dot.radiowaves.left.and.right") }
            ViewerView().tabItem { Label("Xem / PiP", systemImage: "pip") }
            NavigationStack { ScrollView { Text("THOVE-NB 0.5\nNguyễn Bân\n\nMáy phát: chọn ảnh game, căn vùng, lưu và tạo phòng. Bấm Chuẩn bị rồi chọn THOVE-NB Broadcast.\n\nNếu hình phát nằm ở góc đối diện vùng đã chọn, bật Đảo hướng phát 180°.\n\nTối đa 4 người xem dùng chung link và mật khẩu. Mỗi người mở PiP riêng.\n\nChỉnh vùng: dừng Broadcast, lưu vùng mới rồi tạo mã khởi động mới. Không truyền âm thanh. Hai mạng khó xuyên NAT có thể cần TURN.").padding() }.navigationTitle("Hướng dẫn") }.tabItem { Label("Hướng dẫn", systemImage: "questionmark.circle") }
        }.tint(.mint)
    }
}
struct PairingPanel: View {
    let value: String
    let status: String
    var body: some View {
        VStack(spacing: 10) {
            Text("Mã khởi động riêng — không gửi cho người xem").font(.caption.bold())
            if let img = QRSheet(value: value).qrImage() {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 240, height: 240).padding(16).background(.white)
            }
            BroadcastButton().frame(width: 55, height: 55)
            Text("Bấm biểu tượng → chọn THOVE-NB Broadcast. Giữ màn hình này đến khi báo Đã ghép nối. Mã dùng một lần, hết hạn sau 90 giây.").font(.caption)
            Text(status).font(.caption).foregroundStyle(.mint)
        }.frame(maxWidth: .infinity)
    }
}
