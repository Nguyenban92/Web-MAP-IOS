import SwiftUI
import PhotosUI
import ReplayKit
import CoreImage.CIFilterBuiltins
import AVFoundation

@main
struct NBWebMapApp: App {
    var body: some Scene { WindowGroup { RootView().preferredColorScheme(.dark) } }
}

@MainActor
final class AppModel: ObservableObject {
    static let defaultAdminKey = "MG-FvEw0o7qt-STgTZOUbWvbNpS"
    
    @Published var server: String = {
        let saved = UserDefaults.standard.string(forKey: "server") ?? ""
        return saved.isEmpty ? "https://magiao-live-map-aov.onrender.com" : saved
    }() {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    
    @Published var adminKey: String = {
        let saved = UserDefaults.standard.string(forKey: "adminKey") ?? ""
        return saved.isEmpty ? defaultAdminKey : saved
    }() {
        didSet { UserDefaults.standard.set(adminKey, forKey: "adminKey") }
    }
    
    @Published var password = ""
    @Published var crop = Crop(x: 0.055, y: 0.002, width: 0.144, height: 0.311, referenceAspect: 2.165, rotate180: true, version: 3)
    @Published var screenshot: UIImage?
    @Published var room: Room?
    @Published var fps: Double = 30
    @Published var quality: Double = 0.7
    @Published var message = ""
    @Published var working = false
    @Published var status = "Chưa phát"
    @Published var isPublisherLive = false
    @Published var pairing = ""
    @Published var viewersCount: Int = 0
    @Published var maxViewers: Int = 6
    @Published var viewerNames: [String] = []
    private var announcedViewerKeys = Set<String>()
    
    static let calibratedCrop = Crop(x: 0.055, y: 0.002, width: 0.144, height: 0.311, referenceAspect: 2.165, rotate180: true, version: 3)
    
    init() {
        if adminKey.isEmpty {
            adminKey = Self.defaultAdminKey
            UserDefaults.standard.set(Self.defaultAdminKey, forKey: "adminKey")
        }
        if let data = UserDefaults.standard.data(forKey: "crop"), let saved = try? JSONDecoder().decode(Crop.self, from: data) {
            if (saved.version ?? 1) >= 3 && saved.width <= 0.18 {
                crop = saved
            } else {
                crop = Self.calibratedCrop
                UserDefaults.standard.set(try? JSONEncoder().encode(Self.calibratedCrop), forKey: "crop")
            }
        } else {
            crop = Self.calibratedCrop
        }
        if crop.referenceAspect <= 0 { crop.referenceAspect = 2.165 }
        if crop.rotate180 == nil { crop.rotate180 = true }
        if let c = SharedStore.read(), c.enabled {
            room = c.room
            server = c.server
            if (c.crop.version ?? 1) >= 3 && c.crop.width <= 0.18 {
                crop = c.crop
            } else {
                crop = Self.calibratedCrop
            }
            fps = c.fps >= 60 ? 60 : (c.fps >= 30 ? 30 : 15)
            quality = c.quality
        }
    }

    func resetToCalibratedCrop() {
        crop = Self.calibratedCrop
        try? save()
        message = "Đã đặt lại vị trí bản đồ chuẩn Liên Quân Mobile (khớp 100% hình map)."
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
        let pubOnline = v["publisherOnline"] as? Bool ?? false
        let maxV = v["maxViewers"] as? Int ?? 6
        self.maxViewers = maxV
        self.viewersCount = viewers
        if let rawList = v["viewerList"] as? [[String: Any]] {
            var currentKeys = Set<String>()
            var names: [String] = []
            for item in rawList {
                let name = item["name"] as? String ?? ""
                let slot = item["slot"] as? Int ?? -1
                if !name.isEmpty {
                    names.append(name)
                    let key = "\(slot):\(name)"
                    currentKeys.insert(key)
                    if !self.announcedViewerKeys.contains(key) {
                        VoiceAnnouncer.shared.speakJoined(name: name)
                    }
                }
            }
            self.announcedViewerKeys = currentKeys
            self.viewerNames = names
        } else {
            self.viewerNames = []
            self.announcedViewerKeys.removeAll()
        }
        self.isPublisherLive = pubOnline
        if live > 0 {
            status = "Đang phát trực tiếp • \(live)/\(maxV) người xem"
        } else if pubOnline {
            status = viewers > 0 ? "Đang truyền hình ảnh • \(viewers)/\(maxV) người xem" : "Đang phát sóng • Chờ người xem"
        } else {
            status = viewers > 0 ? "Chờ máy phát • Có \(viewers)/\(maxV) người xem" : "Chờ tín hiệu máy phát"
        }
    }

    func save() throws {
        if crop.referenceAspect <= 0 { crop.referenceAspect = 2.165 }
        if crop.rotate180 == nil { crop.rotate180 = true }
        if crop.version == nil { crop.version = 3 }
        guard crop.valid else { throw failure("Vùng chọn không hợp lệ") }
        UserDefaults.standard.set(server, forKey: "server")
        UserDefaults.standard.set(try JSONEncoder().encode(crop), forKey: "crop")
        if let room = room {
            try SharedStore.save(BroadcastConfig(server: server, room: room, crop: crop, fps: fps, quality: quality, enabled: true))
        }
    }

    func failure(_ text: String) -> NSError { NSError(domain: "NBWebMap", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    private func remoteLog(_ text: String) {
        let base = server.isEmpty ? "https://magiao-live-map-aov.onrender.com" : server
        guard let url = URL(string: "\(base)/api/broadcast/log") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["source": "APP", "msg": text])
        URLSession.shared.dataTask(with: req).resume()
    }

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
            if adminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                adminKey = Self.defaultAdminKey
            }
            let trimmedKey = adminKey.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if crop.referenceAspect <= 0 { crop.referenceAspect = 2.165 }
            if crop.rotate180 == nil { crop.rotate180 = true }
            if crop.version == nil { crop.version = 3 }

            let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-app"
            let bodyDict: [String: Any] = [
                "password": password,
                "deviceId": deviceId,
                "crop": [
                    "x": crop.x,
                    "y": crop.y,
                    "width": crop.width,
                    "height": crop.height,
                    "referenceAspect": crop.referenceAspect,
                    "rotate180": crop.rotate180 ?? true,
                    "version": crop.version ?? 3
                ],
                "fps": fps,
                "quality": quality
            ]
            var request = URLRequest(url: url.appendingPathComponent("api/rooms"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 201 else {
                if statusCode == 401 {
                    throw failure("Khóa tạo phòng không chính xác hoặc đã hết hạn.")
                }
                throw failure("Không tạo được phòng (mã lỗi \(statusCode)). Vui lòng kiểm tra lại Key.")
            }
            let createdRoom = try JSONDecoder().decode(Room.self, from: data)
            room = createdRoom
            remoteLog("App created room \(createdRoom.id), URL: \(createdRoom.viewerURL)")
            try save()
            let config = BroadcastConfig(server: server, room: createdRoom, crop: crop, fps: fps, quality: quality, enabled: true)
            try? SharedStore.save(config)
            message = ""
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
            room = nil; pairing = ""; isPublisherLive = false; message = "Đã dừng phát và đóng phòng thành công."
        } catch {
            room = nil; pairing = ""; isPublisherLive = false
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
        let aspect = Double(target.width / target.height)
        crop.referenceAspect = aspect > 1.2 ? aspect : 2.165
        crop.x = 0.055
        crop.y = 0.002
        crop.width = 0.144
        crop.height = 0.311
        crop.version = 3
        try? save()
        if let bytes = normalized.jpegData(compressionQuality: 0.8) { try? bytes.write(to: previewURL, options: .atomic) }
        message = "Đã nhận diện chuẩn vị trí bản đồ Liên Quân Mobile từ ảnh game!"
    }
    
    var previewURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("preview.jpg") }
    func restorePreview() { if screenshot == nil { screenshot = UIImage(contentsOfFile: previewURL.path) } }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var photo: PhotosPickerItem?
    @State private var showQR = false
    @State private var showCropAdjustment = false
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
                        // Card Tạo phòng
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: "crown.fill")
                                        .foregroundStyle(Studio.gold)
                                    Text("MA GIÁO VIP")
                                        .font(.caption.bold())
                                        .foregroundStyle(Studio.gold)
                                }
                                Spacer()
                                HStack(spacing: 5) {
                                    Circle().fill(Color.green).frame(width: 7, height: 7)
                                    Text("SẴN SÀNG")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.green)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.12), in: Capsule())
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Label("MẬT KHẨU", systemImage: "lock.shield.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white.opacity(0.85))
                                
                                SecureField("Mặc định để trống", text: $model.password)
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
                                        Image(systemName: "bolt.fill")
                                            .font(.title3)
                                    }
                                    Text(model.working ? "ĐANG TẠO PHÒNG..." : "TẠO PHÒNG")
                                        .font(.system(size: 18, weight: .black, design: .rounded))
                                }
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(
                                    LinearGradient(
                                        colors: [Studio.gold, Color(red: 1, green: 0.84, blue: 0.38)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 14)
                                )
                                .shadow(color: Studio.gold.opacity(0.35), radius: 8, y: 3)
                            }
                            .disabled(model.working)
                            .opacity(model.working ? 0.6 : 1.0)
                            
                            // Tùy chọn căn chỉnh vị trí Mini-Map (Thu gọn mặc định)
                            VStack(alignment: .center) {
                                Button {
                                    withAnimation(.easeInOut) {
                                        showCropAdjustment.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.caption2)
                                        Text(showCropAdjustment ? "Đóng căn chỉnh bản đồ" : "Căn chỉnh vị trí bản đồ (Tùy chọn)")
                                            .font(.caption2.bold())
                                    }
                                    .foregroundStyle(.white.opacity(0.45))
                                }
                                .frame(maxWidth: .infinity)
                                
                                if showCropAdjustment {
                                    VStack(spacing: 12) {
                                        PhotosPicker(selection: $photo, matching: .images) {
                                            Label("Tải ảnh chụp màn hình game", systemImage: "photo.badge.plus")
                                                .font(.caption.bold())
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 38)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(Studio.gold)
                                        
                                        if let image = model.screenshot {
                                            CropEditor(image: image, crop: $model.crop)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.aqua.opacity(0.3)))
                                        }
                                        
                                        Button("Đặt lại vị trí chuẩn Liên Quân") {
                                            model.resetToCalibratedCrop()
                                        }
                                        .font(.caption2.bold())
                                        .tint(.orange)
                                    }
                                    .padding(.top, 8)
                                }
                            }
                        }
                        .padding(20)
                        .studioCard(accent: Studio.gold)
                        
                    } else if let room = model.room, let url = URL(string: room.viewerURL) {
                        // Card khi đã có phòng phát
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("PHÒNG HOẠT ĐỘNG")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Studio.aqua)
                                    Text(room.id)
                                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button {
                                    showQR = true
                                } label: {
                                    Label("QR", systemImage: "qrcode")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 12)
                                        .frame(height: 34)
                                }
                                .buttonStyle(.bordered)
                                .tint(Studio.aqua)
                            }
                            
                            // Trạng thái phát sóng thời gian thực
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(model.isPublisherLive ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(model.status)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(model.isPublisherLive ? Color.green : Color.orange)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(
                                (model.isPublisherLive ? Color.green : Color.orange).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            
                            // Danh sách người xem thời gian thực
                            if !model.viewerNames.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.2.fill")
                                        .font(.caption)
                                        .foregroundStyle(Studio.aqua)
                                    Text("\(model.viewersCount)/\(model.maxViewers):")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(model.viewerNames, id: \.self) { name in
                                                Text(name)
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Studio.aqua.opacity(0.15))
                                                    .foregroundStyle(Studio.aqua)
                                                    .clipShape(Capsule())
                                                    .overlay(Capsule().stroke(Studio.aqua.opacity(0.4), lineWidth: 1))
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            }
                            
                            // Nút Bật phát ReplayKit trực tiếp
                            BroadcastButtonRow()
                                .frame(height: 54)
                                .shadow(color: Color.blue.opacity(0.3), radius: 6, y: 3)
                            
                            // Hàng 2 nút điều khiển cân đối
                            HStack(spacing: 10) {
                                ShareLink(item: url) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "square.and.arrow.up")
                                        Text("CHIA SẺ LINK")
                                    }
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Studio.aqua)
                                .foregroundStyle(.black)
                                
                                Button(role: .destructive) {
                                    Task { await model.closeRoom() }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "stop.circle.fill")
                                        Text("DỪNG PHÁT")
                                    }
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                            .padding(.top, 2)
                        }
                        .padding(18)
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
                    
                    HeroBannerView()
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
            .onAppear { model.restorePreview() }
            .onChange(of: photo) { item in Task { await model.load(item) } }
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

final class BroadcastButtonRowView: UIView {
    let picker = RPSystemBroadcastPickerView()
    private let titleLabel = UILabel()
    private let subLabel = UILabel()
    private let iconView = UIImageView()
    private let textStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor(red: 0.12, green: 0.28, blue: 0.82, alpha: 1.0)
        layer.cornerRadius = 14
        clipsToBounds = true

        iconView.image = UIImage(systemName: "record.circle.fill")
        iconView.tintColor = UIColor(red: 1.0, green: 0.28, blue: 0.35, alpha: 1.0)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isUserInteractionEnabled = false

        titleLabel.text = "BẬT PHÁT RADAR"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.isUserInteractionEnabled = false

        subLabel.text = "Chạm để kích hoạt phát sóng"
        subLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.isUserInteractionEnabled = false

        let col = UIStackView(arrangedSubviews: [titleLabel, subLabel])
        col.axis = .vertical
        col.spacing = 2
        col.isUserInteractionEnabled = false

        textStack.axis = .horizontal
        textStack.spacing = 10
        textStack.alignment = .center
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isUserInteractionEnabled = false
        textStack.addArrangedSubview(iconView)
        textStack.addArrangedSubview(col)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])

        picker.showsMicrophoneButton = false
        picker.preferredExtension = nil
        picker.backgroundColor = .clear
        picker.alpha = 0.05
        addSubview(picker)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
        for sub in picker.subviews {
            sub.frame = bounds
            for nested in sub.subviews {
                nested.frame = bounds
            }
        }
    }
}

struct BroadcastButtonRow: UIViewRepresentable {
    func makeUIView(context: Context) -> BroadcastButtonRowView {
        BroadcastButtonRowView()
    }
    func updateUIView(_ uiView: BroadcastButtonRowView, context: Context) {}
}

struct BigBroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> BroadcastButtonRowView {
        BroadcastButtonRowView()
    }
    func updateUIView(_ uiView: BroadcastButtonRowView, context: Context) {}
}

struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> BroadcastButtonRowView {
        BroadcastButtonRowView()
    }
    func updateUIView(_ uiView: BroadcastButtonRowView, context: Context) {}
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
                    Text("Ma Giáo Live Map AOV\n\n1. Nhập mật khẩu người xem (hoặc để trống) rồi bấm TẠO PHÒNG.\n2. Bấm Gửi link chia sẻ cho đồng đội hoặc quét mã QR.\n3. Bấm Bắt đầu phát → Chạm biểu tượng ghi màn hình → Chọn Live - Ma Giáo AOV.\n4. Sau trận đấu bấm DỪNG PHÁT.")
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

struct HeroBannerView: View {
    var body: some View {
        let image: Image = {
            if let uiImg = UIImage(named: "HeroArt") {
                return Image(uiImage: uiImg)
            } else if let path = Bundle.main.path(forResource: "HeroArt", ofType: "jpg"),
                      let uiImg = UIImage(contentsOfFile: path) {
                return Image(uiImage: uiImg)
            } else {
                return Image("HeroArt")
            }
        }()
        
        ZStack(alignment: .top) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
            
            // Seamless top fade matching illustration
            LinearGradient(
                stops: [
                    .init(color: Studio.background, location: 0.0),
                    .init(color: Studio.background.opacity(0.85), location: 0.12),
                    .init(color: Studio.background.opacity(0.3), location: 0.28),
                    .init(color: .clear, location: 0.5)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Subtle bottom fade
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.72),
                    .init(color: Studio.background.opacity(0.6), location: 0.88),
                    .init(color: Studio.background, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .padding(.horizontal, -16)
        .allowsHitTesting(false)
    }
}

final class VoiceAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceAnnouncer()
    private let synth = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        synth.delegate = self
    }
    
    func speakJoined(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let text = "\(trimmed) Lỏ đã vào phòng"
        DispatchQueue.main.async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                NSLog("[VoiceAnnouncer] AVAudioSession error: %@", error.localizedDescription)
            }
            
            let utterance = AVSpeechUtterance(string: text)
            if let viVoice = AVSpeechSynthesisVoice(language: "vi-VN") {
                utterance.voice = viVoice
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            }
            utterance.rate = 0.50
            utterance.pitchMultiplier = 1.15
            utterance.volume = 1.0
            self.synth.speak(utterance)
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
