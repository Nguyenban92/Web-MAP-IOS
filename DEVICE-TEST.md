# Kiểm thử trên thiết bị — chưa thực hiện

Ghi model/iOS hai máy, loại mạng, cấu hình, FPS/RTT quan sát; không ghi token hoặc khóa.

1. Build workflow xanh, cài cùng IPA được ký đúng trên hai máy. NB Map Broadcast phải xuất hiện và khởi động.
2. Cùng Wi-Fi, 30 fps/Cân bằng: tạo phòng, ghép QR, thấy đúng vùng trên máy xem. Thử đổi chiều; sai tỉ lệ phải đen.
3. Bật PiP, chuyển máy xem vào game 10 phút; hình phải tiếp tục cập nhật. Đo FPS, nhiệt và RAM bằng Xcode nếu có. Đặc biệt theo dõi extension bị hệ thống dừng do bộ nhớ.
4. Thử hai mạng khác nhau. Nếu P2P không nối được, cấu hình TURN thật và bật Chỉ dùng TURN trên máy xem; thống kê phải báo TURN và có hình.
5. Thử 15, 30, 60 fps ở từng mức chất lượng. Chọn mức ổn định khi cả hai máy chơi game, không chỉ khi ở màn hình chính.
6. Đo trễ đầu cuối bằng quay chung đồng hồ thay đổi trên màn hình phát và hình nhận. RTT chỉ dùng chẩn đoán mạng.
7. Ngắt mạng, chuyển Wi-Fi/4G; kiểm tra hình cũ biến mất khoảng 3 giây và phiên dừng sau mất server quá 15 giây. Kết nối lại khi cần.
8. Đóng phòng; hình dừng, link cũ không vào được. Máy xem thứ hai không được chiếm phòng đang có người xem.
9. Dừng Broadcast, thay vùng/FPS, tạo QR mới; kiểm tra cấu hình mới. QR cũ không dùng lại được.
10. Khóa/mở máy, dừng PiP và quay lại app. Ghi rõ hành vi thực tế, không coi bản này đạt nghiệm thu trước khi kiểm tra.
