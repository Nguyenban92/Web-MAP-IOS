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
    @Published var server: String = {
        let saved = UserDefaults.standard.string(forKey: "server") ?? ""
        return saved.isEmpty ? "https://magiao-live-map-aov.onrender.com" : saved
    }() {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    
    @Published var adminKey: String = UserDefaults.standard.string(forKey: "adminKey") ?? "" {
        didSet { UserDefaults.standard.set(adminKey, forKey: "adminKey") }
    }
    
    @Published var password = ""
    @Published var crop = Crop()
    @Published var screenshot: UIImage?
    @Published var room: Room?
    @Published var fps: Double = 30
    @Published var quality: Double = 0.7
    @Published var message = ""
    @Published var working = false
    @Published var status = "Chưa phát"
    @Published var pairing = ""
    
    init() {
        if let savedKey = UserDefaults.standard.string(forKey: "adminKey"), !savedKey.isEmpty {
            adminKey = savedKey
        }
        if let data = UserDefaults.standard.data(forKey: "crop"), let saved = try? JSONDecoder().decode(Crop.self, from: data) {
            crop = saved
        }
        if crop.referenceAspect <= 0 { crop.referenceAspect = 2.16 }
        if crop.rotate180 == nil { crop.rotate180 = true }
        if let c = SharedStore.read(), c.enabled {
            room = c.room
            server = c.server
            crop = c.crop
            fps = c.fps >= 60 ? 60 : (c.fps >= 30 ? 30 : 15)
            quality = c.quality
        }
    }

    func preparePairing() async {
        guard let room = room else { return }
        working = true; defer { working = false }
        do {
            try save()
            let config = BroadcastConfig(server: server, room: room, crop: crop, fps: fps, quality: quality, enabled: true)
            guard let pairUrl = URL(string: "\(server)/api/rooms/\(room.id)/pair") else {
                throw failure("Địa chỉ ghép nối không hợp lệ")
            }
            var req = URLRequest(url: pairUrl)
            req.httpMethod = "POST"; req.timeoutInterval = 10
            req.setValue("Bearer \(room.publishToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(config)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 201,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let url = value["pairURL"] else {
                throw failure("Không tạo được mã khởi động. Kiểm tra kết nối mạng.")
            }
            pairing = "NBWM2:" + url
        } catch { message = error.localizedDescription }
    }

    private var refreshing = false
    func refreshStatus() async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        guard let room = room, let url = URL(string: "\(server)/api/rooms/\(room.id)/status") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        req.setValue("Bearer \(room.publishToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let viewers = v["viewers"] as? Int ?? 0, live = v["liveViewers"] as? Int ?? 0
        status = live > 0 ? "Đang phát trực tiếp • \(live)/4 người xem" : ((v["paired"] as? Bool == true) ? "Đã ghép nối • Đang chờ người xem (\(viewers)/4)" : "Chờ bật Ma Giáo Live Map Broadcast")
    }

    func save() throws {
        if crop.referenceAspect <= 0 { crop.referenceAspect = 2.16 }
        if crop.rotate180 == nil { crop.rotate180 = true }
        guard crop.valid else { throw failure("Vùng chọn không hợp lệ") }
        UserDefaults.standard.set(server, forKey: "server")
        UserDefaults.standard.set(try JSONEncoder().encode(crop), forKey: "crop")
        if let room = room {
            try SharedStore.save(BroadcastConfig(server: server, room: room, crop: crop, fps: fps, quality: quality, enabled: true))
        }
    }

    func failure(_ text: String) -> NSError { NSError(domain: "NBWebMap", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    func createRoom() async {
        working = true; defer { working = false }
        do {
            guard room == nil else { throw failure("Đang có phòng mở. Bấm Dừng Phát trước khi tạo phòng mới.") }
            server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            while server.hasSuffix("/") { server.removeLast() }
            if server.isEmpty { server = "https://magiao-live-map-aov.onrender.com" }
            guard let url = URL(string: server), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else {
                throw failure("Địa chỉ máy chủ không hợp lệ: \(server)")
            }
            let trimmedKey = adminKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { throw failure("Vui lòng dán Khóa tạo phòng (Key).") }
            adminKey = trimmedKey
            
            if crop.referenceAspect <= 0 { crop.referenceAspect = 2.16 }
            if crop.rotate180 == nil { crop.rotate180 = true }

            var request = URLRequest(url: url.appendingPathComponent("api/rooms"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 201 else {
                if statusCode == 401 {
                    throw failure("Khóa tạo phòng không chính xác hoặc đã hết hạn.")
                }
                throw failure("Không tạo được phòng (mã lỗi \(statusCode)). Vui lòng kiểm tra lại Key.")
            }
            room = try JSONDecoder().decode(Room.self, from: data)
            try save()
            message = "Phòng đã sẵn sàng! Bấm 'Bắt đầu phát' để lấy mã ghép nối."
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
            room = nil; pairing = ""; message = "Đã dừng phát và đóng phòng thành công."
        } catch {
            room = nil; pairing = ""
            message = "Đã dừng phát. Nếu còn biểu tượng ghi màn hình đỏ trên iPhone, hãy bấm dừng."
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
    }
    
    var previewURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("preview.jpg") }
    func restorePreview() { if screenshot == nil { screenshot = UIImage(contentsOfFile: previewURL.path) } }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showQR = false
    @State private var showKey = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header Brand
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MA GIÁO")
                                .font(.system(size: 32, weight: .black, design: .rounded))
                                .foregroundStyle(LinearGradient(colors: [Studio.gold, Color(red: 1, green: 0.91, blue: 0.58)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Text("LIVE MAP AOV")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(3)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        // Status badge
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.room != nil ? Color.green : Studio.aqua)
                                .frame(width: 8, height: 8)
                            Text(model.room != nil ? "Đang mở" : "Sẵn sàng")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    }
                    .padding(.top, 4)
                    
                    if model.room == nil {
                        // Card nhập Key & Tạo phòng
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Khóa tạo phòng (Key)", systemImage: "key.fill")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Studio.gold)
                                
                                HStack(spacing: 8) {
                                    Group {
                                        if showKey {
                                            TextField("Dán khóa tạo phòng vào đây...", text: $model.adminKey)
                                                .textInputAutocapitalization(.never)
                                                .autocorrectionDisabled()
                                        } else {
                                            SecureField("Dán khóa tạo phòng vào đây...", text: $model.adminKey)
                                        }
                                    }
                                    .font(.subheadline)
                                    .padding(12)
                                    .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.aqua.opacity(0.3), lineWidth: 1))
                                    
                                    Button {
                                        showKey.toggle()
                                    } label: {
                                        Image(systemName: showKey ? "eye.slash.fill" : "eye.fill")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 38, height: 44)
                                    }
                                    
                                    if !model.adminKey.isEmpty {
                                        Button {
                                            model.adminKey = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                                .frame(width: 38, height: 44)
                                        }
                                    } else {
                                        Button("Dán") {
                                            if let clip = UIPasteboard.general.string {
                                                model.adminKey = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                            }
                                        }
                                        .font(.subheadline.bold())
                                        .buttonStyle(.bordered)
                                        .tint(Studio.aqua)
                                        .frame(height: 44)
                                    }
                                }
                                
                                Text("Khóa sẽ được lưu vĩnh viễn trên máy trừ khi bấm xóa.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Mật khẩu người xem (Tùy chọn)", systemImage: "lock.shield")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white.opacity(0.85))
                                
                                SecureField("Để trống nếu không đặt mật khẩu", text: $model.password)
                                    .font(.subheadline)
                                    .padding(12)
                                    .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
                            }
                            
                            // Nút TẠO PHÒNG LỚN (Hero Button)
                            Button {
                                Task { await model.createRoom() }
                            } label: {
                                HStack(spacing: 10) {
                                    if model.working {
                                        ProgressView().tint(.black)
                                    } else {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.title3)
                                    }
                                    Text(model.working ? "ĐANG TẠO PHÒNG..." : "TẠO PHÒNG")
                                        .font(.system(size: 18, weight: .black, design: .rounded))
                                }
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(
                                    LinearGradient(
                                        colors: [Studio.gold, Color(red: 1, green: 0.84, blue: 0.38)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 16)
                                )
                                .shadow(color: Studio.gold.opacity(0.4), radius: 10, y: 4)
                            }
                            .disabled(model.working || model.adminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity((model.working || model.adminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.6 : 1.0)
                        }
                        .padding(20)
                        .studioCard(accent: Studio.gold)
                        
                    } else if let room = model.room, let url = URL(string: room.viewerURL) {
                        // Card khi đã có phòng phát
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("PHÒNG ĐANG HOẠT ĐỘNG")
                                        .font(.caption.bold())
                                        .foregroundStyle(Studio.aqua)
                                    Text("Mã: \(room.id)")
                                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button {
                                    showQR = true
                                } label: {
                                    Label("QR", systemImage: "qrcode")
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 14)
                                        .frame(height: 38)
                                }
                                .buttonStyle(.bordered)
                                .tint(Studio.aqua)
                            }
                            
                            HStack(spacing: 10) {
                                ShareLink(item: url) {
                                    Label("Gửi link", systemImage: "square.and.arrow.up")
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Studio.aqua)
                                .foregroundStyle(.black)
                                
                                Button {
                                    Task { await model.preparePairing() }
                                } label: {
                                    Label("Bắt đầu phát", systemImage: "antenna.radiowaves.left.and.right")
                                        .font(.subheadline.bold())
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color(red: 0.1, green: 0.5, blue: 0.95))
                                .disabled(model.working)
                            }
                            
                            if !model.pairing.isEmpty {
                                PairingPanel(value: model.pairing, status: model.status)
                            }
                            
                            // Trạng thái người xem
                            HStack(spacing: 10) {
                                Circle().fill(Studio.aqua).frame(width: 8, height: 8)
                                Text(model.status)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Studio.aqua)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(Studio.aqua.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.aqua.opacity(0.25), lineWidth: 1))
                            
                            // Nút DỪNG PHÁT lớn, nổi bật màu đỏ
                            Button(role: .destructive) {
                                Task { await model.closeRoom() }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.title3)
                                    Text(model.working ? "ĐANG DỪNG..." : "DỪNG PHÁT")
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .foregroundStyle(.white)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.9, green: 0.2, blue: 0.25), Color(red: 0.75, green: 0.1, blue: 0.15)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 14)
                                )
                                .shadow(color: Color.red.opacity(0.35), radius: 8, y: 3)
                            }
                            .disabled(model.working)
                            .padding(.top, 4)
                        }
                        .padding(20)
                        .studioCard(accent: Studio.aqua)
                    }
                    
                    if !model.message.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text(model.message)
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 4)
                    }
                    
                    // Cấu hình chuẩn tích hợp
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cấu hình chuẩn tối ưu sẵn:")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.7))
                        Text("• Tỷ lệ mini-map: Góc trái chuẩn Liên Quân Mobile")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("• Tốc độ: 30 FPS • H.264 WebRTC siêu mượt • Độ trễ < 0.3s")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("• Tự động đảo hướng phát 180° chuẩn theo màn hình game")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                .padding()
            }
            .background(
                LinearGradient(
                    colors: [Studio.background, Color(red: 0.01, green: 0.08, blue: 0.14), Studio.background],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()
            )
            .onReceive(timer) { _ in Task { await model.refreshStatus() } }
            .sheet(isPresented: $showQR) {
                if let room = model.room {
                    QRSheet(value: room.viewerURL)
                }
            }
        }
    }
}

enum Studio {
    static let background = Color(red: 0.015, green: 0.035, blue: 0.065)
    static let panel = Color(red: 0.055, green: 0.085, blue: 0.125)
    static let aqua = Color(red: 0.08, green: 0.92, blue: 0.96)
    static let gold = Color(red: 0.95, green: 0.72, blue: 0.30)
}

struct StudioCardModifier: ViewModifier {
    let accent: Color
    func body(content: Content) -> some View {
        content
            .background(LinearGradient(colors: [Studio.panel.opacity(0.98), Studio.background.opacity(0.94)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(LinearGradient(colors: [accent.opacity(0.72), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: accent.opacity(0.10), radius: 14, y: 6)
    }
}

extension View {
    func studioCard(accent: Color = Studio.gold) -> some View {
        modifier(StudioCardModifier(accent: accent))
    }
}

struct StudioGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline.bold()).foregroundStyle(Studio.gold)
            configuration.content
        }
        .padding(16)
        .studioCard()
    }
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
            if let image = qrImage() {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 260, height: 260).padding().background(.white)
            }
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
            NavigationStack {
                ScrollView {
                    Text("Ma Giáo Live Map AOV\n\n1. Nhập Khóa tạo phòng (Key) rồi bấm TẠO PHÒNG.\n2. Bấm Gửi link chia sẻ cho đồng đội hoặc quét mã QR.\n3. Bấm Bắt đầu phát → Chạm biểu tượng ghi màn hình → Chọn Ma Giáo Live Map Broadcast.\n4. Sau trận đấu bấm DỪNG PHÁT.")
                        .padding()
                }
                .navigationTitle("Hướng dẫn")
            }.tabItem { Label("Hướng dẫn", systemImage: "questionmark.circle") }
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
            Text("Bấm biểu tượng → chọn Ma Giáo Live Map Broadcast. Giữ màn hình này đến khi báo Đã ghép nối. Mã dùng một lần, hết hạn sau 90 giây.").font(.caption)
            Text(status).font(.caption).foregroundStyle(.mint)
        }.frame(maxWidth: .infinity)
    }
}
