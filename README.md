# THOVE-NB 0.5 — WebRTC

Mã nguồn app iPhone phát một vùng màn hình sang một iPhone khác, xem trong cửa sổ PiP khi chơi game. iOS 16+. Đây là bản triển khai cần kiểm thử thiết bị, không phải IPA đã biên dịch hay sản phẩm đã nghiệm thu.

## Thay đổi

- WebRTC truyền video thay chuỗi JPEG; ưu tiên H.264, có codec dự phòng.
- Cắt và thu nhỏ ngay trên máy phát; chỉ vùng chọn được đưa vào video.
- Ba mức 15/30/60 fps mục tiêu; mặc định 30 fps. Cạnh dài tối đa 384/640/960 pixel tùy chất lượng.
- WebRTC tự điều chỉnh theo mạng, giới hạn bitrate khoảng 1,06–1,76 Mbps theo mức chọn. Giảm tối đa còn 15 fps khi máy báo nóng nghiêm trọng.
- Hàng đợi khung hình giới hạn, pool bộ đệm giới hạn; tránh tích lũy hình cũ.
- Native PiP, số FPS nhận, RTT và chỉ báo P2P/TURN; không truyền âm thanh.
- Tối đa bốn máy xem mỗi phòng. Tự thương lượng lại khi đường truyền lỗi; ẩn hình cũ sau khoảng 3 giây, dừng phiên khi mất máy chủ quá 15 giây.
- Có tùy chọn Đảo hướng phát 180° để khớp vùng cắt khi game và ảnh mẫu dùng hai hướng cầm iPhone đối diện.
- Ghép nối bằng QR đọc cục bộ qua ReplayKit, không yêu cầu App Groups.

60 fps là mục tiêu cấu hình, không phải kết quả đã đo. RTT không phải tổng độ trễ hình ảnh. ReplayKit, codec, nhiệt độ, Wi-Fi và mạng di động đều ảnh hưởng.

## Build IPA

1. Giải nén, đưa toàn bộ nội dung thư mục này vào gốc repository GitHub, gồm `.github/workflows`.
2. Actions → Build NB Web Map IPA → Run workflow. Điền Bundle ID phù hợp profile ký.
3. Workflow chạy kiểm tra Node, tạo project XcodeGen, tải WebRTC 154.0.0 và build trên macOS.
4. Khi thành công, tải artifact `NB-Web-Map-IPA`, giải nén lấy `NB-Web-Map-unsigned.ipa`.
5. Ký cả app và `PlugIns/Broadcast.appex`; xem SIGNING.txt. Nếu build lỗi, tải artifact `build-error-log`.

Không tải chứng chỉ hoặc mật khẩu lên repository. WebRTC được tải lúc build, không nằm trong gói nguồn; IPA sẽ lớn hơn bản JPEG. Actions có hạn mức riêng của tài khoản, không mặc định mọi lượt build đều miễn phí.

## Chạy máy chủ

Cần một dịch vụ Node.js 22+ có URL HTTPS công khai. Gói này chưa triển khai hosting cho bạn.

```
cd server
npm test
npm start
```

Thiết lập biến môi trường trước khi chạy:

| Biến | Giá trị |
|---|---|
| ADMIN_KEY | Chuỗi ngẫu nhiên ít nhất 24 ký tự, chỉ người phát biết |
| PUBLIC_URL | URL gốc HTTPS thật, không có đường dẫn con |
| PORT | Cổng do hosting cung cấp, mặc định 8080 |
| TURN_URLS | Tùy chọn: các URL turn:/turns: cách nhau dấu phẩy |
| TURN_SECRET | Tùy chọn: shared secret của dịch vụ TURN REST tương thích coturn |
| ICE_SERVERS_JSON | Tùy chọn: mảng ICE servers thay danh sách STUN mặc định |

Tạo khóa: `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.
Health check: `GET /health` trả `{"ok":true}`. Chỉ chạy một instance, dữ liệu phòng ở RAM; restart sẽ đóng phòng. Phòng không tự hết hạn khi publisher vẫn đang phát; phòng chỉ đóng khi người phát chủ động đóng hoặc mất publisher heartbeat quá 3 phút. Thời gian chờ bắt đầu phát là 10 phút.

Nếu đã có VPS/tên miền: trong `deploy`, chép `.env.example` thành `.env`, điền thông tin rồi `docker compose up -d --build`. Caddy cần cổng 80/443. Không commit `.env`.

### Hai mạng khác nhau và chi phí

Mặc định thử P2P với STUN; HTTP server chỉ ghép nối, không chuyển tiếp video. Hai mạng có thể kết nối trực tiếp nhưng không được bảo đảm. Nếu bị NAT/tường lửa chặn, cần TURN thực sự. Có sẵn hỗ trợ TURN và chế độ ép TURN để kiểm tra, nhưng không kèm tài khoản TURN/hosting miễn phí. Không thể hứa miễn phí vô hạn và kết nối tốt trên mọi mạng.

`TURN_URLS` + `TURN_SECRET` phải khai báo cùng nhau và khớp cấu hình dịch vụ TURN; khai báo biến không tự tạo TURN. Backend cấp credential HMAC ngắn hạn, không gửi shared secret xuống app. Không dùng khóa thật trong mã nguồn. Với nhà cung cấp dùng credential tĩnh, cấu hình ICE_SERVERS_JSON theo tài liệu của họ (credential này sẽ được gửi cho client được cấp quyền).

## Dùng trên hai iPhone

**Máy phát:** Tab Phát → nhập HTTPS và ADMIN_KEY → chọn ảnh chụp game đúng chiều → căn vùng cắt → chọn 30 fps/Cân bằng trước → Tạo phòng → gửi link xem. Bấm Chuẩn bị, giữ QR trên màn hình → nút phát → THOVE-NB Broadcast → bắt đầu. Một phòng hỗ trợ tối đa 4 người xem P2P độc lập.

**Máy xem:** Cài cùng app → tab Xem / PiP → dán link đầy đủ → nhập mật khẩu nếu có → Kết nối → đợi hình → Mở cửa sổ nhỏ PiP → vào game. iOS quản lý kích thước/vị trí cửa sổ. Trình duyệt cũng xem được WebRTC, nhưng ưu tiên app khi cần PiP trên iPhone.

Đổi vùng hoặc FPS: dừng Broadcast, lưu cấu hình mới, tạo QR mới và phát lại. Dừng bằng nút ghi màn hình iOS; Đóng phòng thu hồi link khi server xác nhận.

Chỉ vùng đã cắt được truyền, nhưng nội dung ứng dụng khác hoặc thông báo xuất hiện trong vùng đó cũng có thể lọt vào video. App không tự nhận biết game. Tắt thông báo và dừng phát trước khi mở nội dung riêng tư. Sai tỉ lệ màn hình sẽ gửi hình đen.

## Kiểm chứng và giới hạn bàn giao

Đã chạy 10 kiểm tra Node thành công: quyền truy cập, cách ly phòng, mật khẩu, thu hồi/đóng phòng, giới hạn payload, ghép nối một lần, vai trò signaling, phiên cũ, ICE và credential TURN. Đã kiểm tra cú pháp JavaScript. Đây không phải kiểm thử video đầu cuối.

Môi trường bàn giao là Linux, chưa chạy Xcode build, chưa xác nhận ESign/Broadcast, chưa đo RAM extension, FPS thực tế hay PiP chạy nền. Cần hoàn tất các bước trong DEVICE-TEST.md trước khi sử dụng thường xuyên.

Các endpoint JPEG cũ vẫn còn để tương thích; app và viewer v0.5 dùng WebRTC.
