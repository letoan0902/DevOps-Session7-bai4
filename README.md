# DevOps - Session 07 - Bài 4

Cấu hình Reverse Proxy Nginx cho ứng dụng Spring Boot.

Bài tập yêu cầu cấu hình một Nginx Server Block làm Reverse Proxy tại cổng 80: lưu lượng tĩnh ở `/` được Nginx phục vụ trực tiếp từ `/var/www/html/`, mọi yêu cầu bắt đầu bằng `/api/` được chuyển tiếp (`proxy_pass`) đến ứng dụng Spring Boot đang chạy ở `127.0.0.1:8082`. Site được kích hoạt bằng symlink sang `sites-enabled` và kiểm tra cú pháp bằng `nginx -t` trước khi reload.

## Mục lục

- [Báo cáo chi tiết (homework/session_07/ex4/README.md)](homework/session_07/ex4/README.md)
  - Khái niệm Reverse Proxy và sơ đồ luồng lưu lượng
  - Kiểm tra backend Spring Boot trước khi cấu hình
  - Tạo trang tĩnh và file `spring-proxy.conf`
  - Dấu `/` cuối trong `proxy_pass` và các header chuyển tiếp
  - Kích hoạt site, gỡ site cũ chiếm `default_server`
  - Kết quả `nginx -t` và kết quả kiểm tra bằng `curl`
  - Minh họa lỗi 502 Bad Gateway
  - Script triển khai, bảng xử lý sự cố, đối chiếu yêu cầu

## Danh sách file

| Đường dẫn | Mô tả |
|---|---|
| `homework/session_07/ex4/README.md` | Báo cáo bài làm |
| `homework/session_07/ex4/spring-proxy.conf` | Server block Nginx: `/` phục vụ tĩnh, `/api/` proxy đến `http://127.0.0.1:8082/` |
| `homework/session_07/ex4/index.html` | Trang tĩnh hiển thị thông tin học viên, đặt tại `/var/www/html/` |
| `homework/session_07/ex4/deploy_proxy.sh` | Script bash idempotent triển khai cấu hình (có `nginx -t` trước reload, sao lưu cấu hình cũ) |
| `homework/session_07/ex4/terminal_log.txt` | Log đầy đủ phiên làm việc theo thứ tự thời gian |
