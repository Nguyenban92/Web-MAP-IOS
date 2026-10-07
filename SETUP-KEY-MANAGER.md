# THOVE-NB - Thiết lập trang quản lý key

Trang quản lý nằm tại `https://TEN-MAY-CHU.onrender.com/admin`.

## 1. Tạo Google Sheet

Tạo Google Sheet mới tên `THOVE-NB Key Manager`, chọn **Tiện ích mở rộng > Apps Script**, xóa mã mẫu và dán toàn bộ file `google-apps-script/Code.gs`.

## 2. Tạo bí mật đồng bộ

Trong Apps Script chọn **Project Settings > Script properties > Add script property**:

- Property: `KEY_STORE_SECRET`
- Value: chuỗi bí mật tối thiểu 24 ký tự, khác `ADMIN_KEY`.

## 3. Deploy Apps Script

Chọn **Deploy > New deployment > Web app**; Execute as **Me**; Who has access **Anyone**. Deploy và sao chép URL kết thúc bằng `/exec`. Mọi yêu cầu vẫn phải có `KEY_STORE_SECRET` chính xác.

## 4. Thêm vào Render

Trong **Environment** thêm `KEY_STORE_URL` là URL `/exec` và `KEY_STORE_SECRET` là chuỗi ở bước 2. Giữ nguyên các biến hiện có rồi bấm **Save, rebuild, and deploy**.

## 5. Sử dụng

Mở `/admin`, đăng nhập bằng `ADMIN_KEY`, tạo key rồi chỉ gửi chuỗi key cho người sử dụng. Khóa hoặc xóa key sẽ đóng ngay phòng của key đó. `PUBLISHER_KEYS` vẫn hoạt động như phương án dự phòng.
