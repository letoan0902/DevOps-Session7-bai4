# Bài 4 - Cấu hình Reverse Proxy Nginx cho ứng dụng Spring Boot

Môn DevOps - Session 07. Ngày thực hiện: Thứ Năm, 2026-10-08, khoảng 09:01 đến 09:44 (giờ máy chủ, múi giờ +07).

## 1. Mục tiêu và bối cảnh

Mục tiêu: cấu hình Nginx Server Block làm Reverse Proxy tại cổng 80, dùng Path Matching (khối `location`) để phân luồng. Lưu lượng tĩnh do Nginx phục vụ trực tiếp; lưu lượng động bắt đầu bằng `/api/` được chuyển tiếp đến ứng dụng Spring Boot ở `127.0.0.1:8082`. Site được kích hoạt bằng symlink sang `sites-enabled`, kiểm tra cú pháp bằng `nginx -t` trước khi reload, rồi kiểm chứng bằng `curl`.

Môi trường thực hiện:

| Hạng mục | Giá trị |
|---|---|
| Máy chủ | Ubuntu 24.04.3 LTS, kernel 6.8.0-87-generic, `nginx/1.24.0 (Ubuntu)` |
| Hostname / IP | `halo` / `103.116.104.228` |
| Tài khoản | `devops` (uid 1001, thuộc nhóm sudo) |
| Kết nối | `ssh -p 2222 -i ~/.ssh/id_ed25519_ptit_s02 devops@103.116.104.228` |
| Backend | Dịch vụ `spring-app.service` (Spring Boot 3.3.4, OpenJDK 21.0.4), chạy bằng user `java-runner`, nghe tại `127.0.0.1:8082` |
| Máy cá nhân | Windows, Git Bash, IP công cộng `113.161.72.19`, curl 8.15.0 (curl trên máy chủ là 8.5.0) |
| Tường lửa UFW | Cho phép 2222, 80, 8080, 8090 (không mở 8082) |

Các file trong thư mục bài nộp:

| File | Vai trò |
|---|---|
| `spring-proxy.conf` | Server block Nginx: `/` phục vụ tĩnh, `/api/` proxy đến Spring Boot |
| `index.html` | Trang tĩnh hiển thị thông tin học viên, đặt tại `/var/www/html/` |
| `deploy_proxy.sh` | Script bash idempotent tự động hóa toàn bộ các bước triển khai |
| `terminal_log.txt` | Log đầy đủ phiên làm việc theo thứ tự thời gian |

Các đoạn trích trong báo cáo này lấy từ [terminal_log.txt](terminal_log.txt).

## 2. Kiến thức nền: Reverse Proxy

### 2.1 Khái niệm

Reverse Proxy là máy chủ đứng trước một hoặc nhiều máy chủ ứng dụng (backend). Client chỉ giao tiếp với proxy; proxy nhận yêu cầu, chọn backend phù hợp, chuyển tiếp yêu cầu rồi trả phản hồi về cho client. Với client, proxy chính là máy chủ thật. Khác với forward proxy (đứng thay mặt client đi ra Internet), reverse proxy đứng thay mặt máy chủ trước Internet.

### 2.2 Vì sao nên đặt Nginx phía trước Spring Boot

- Một cổng vào duy nhất: người dùng chỉ biết cổng 80 (và 443 sau này); nhiều ứng dụng backend ở các cổng khác nhau được gom về một địa chỉ.
- Ẩn backend: Spring Boot chỉ nghe trên `127.0.0.1`, không có đường vào trực tiếp từ Internet, giảm bề mặt tấn công.
- TLS termination: Nginx có thể xử lý HTTPS, backend chỉ cần nói HTTP thuần ở mạng nội bộ.
- Phục vụ file tĩnh nhanh: Nginx đọc file tĩnh hiệu quả hơn nhiều so với đẩy qua JVM, giúp backend chỉ lo xử lý nghiệp vụ.
- Cân bằng tải và mở rộng về sau: khi có nhiều bản sao Spring Boot, chỉ cần khai báo thêm khối `upstream`, client không phải đổi gì.

### 2.3 Sơ đồ luồng lưu lượng

```text
                          +----------------------------------------+
  +--------+   HTTP :80   |               Nginx :80                |
  | Client |------------->|    server_name _;  (default_server)    |
  +--------+              |                                        |
                          |   location /      --> /var/www/html/   |   tinh
                          |   location /api/  --> 127.0.0.1:8082   |   dong
                          +----------------------------------------+
```

### 2.4 Path Matching bằng `location`

Nginx chọn khối `location` theo tiền tố khớp dài nhất. Yêu cầu `/api/health` khớp cả `location /` lẫn `location /api/`, nhưng `/api/` dài hơn nên được chọn. Khối `location /` đóng vai trò mặc định cho mọi đường dẫn còn lại. Theo tài liệu Nginx, khi `location` kết thúc bằng dấu `/` và dùng `proxy_pass`, yêu cầu `/api` (thiếu dấu `/`) sẽ được tự động chuyển hướng 301 sang `/api/`.

## 3. Bước 1 - Kiểm tra backend trước khi cấu hình

Đăng nhập SSH, ghi nhận phiên bản Nginx và hiện trạng `sites-enabled`:

```bash
devops@halo:~$ nginx -v
nginx version: nginx/1.24.0 (Ubuntu)
devops@halo:~$ systemctl is-active nginx
active
devops@halo:~$ ls -l /etc/nginx/sites-enabled/
total 0
lrwxrwxrwx 1 root root 42 Oct  2 14:16 multi-port.conf -> /etc/nginx/sites-available/multi-port.conf
lrwxrwxrwx 1 root root 38 Oct  2 15:16 my-app.conf -> /etc/nginx/sites-available/my-app.conf
devops@halo:~$ grep -n default_server /etc/nginx/sites-enabled/*
/etc/nginx/sites-enabled/my-app.conf:7:    # default_server: nhận mọi yêu cầu không khớp server_name nào
/etc/nginx/sites-enabled/my-app.conf:9:    listen 80 default_server;
/etc/nginx/sites-enabled/my-app.conf:10:    listen [::]:80 default_server;
```

Chỉ có `my-app.conf` đang khai báo `default_server` cho cổng 80 (xử lý ở mục 6). Tiếp theo xác nhận dịch vụ Spring Boot đang chạy (dòng đầu của `systemctl status` bắt đầu bằng `*`):

```bash
devops@halo:~$ systemctl status spring-app.service --no-pager -l
* spring-app.service - Spring Boot Application
     Loaded: loaded (/etc/systemd/system/spring-app.service; enabled; preset: enabled)
     Active: active (running) since Thu 2026-10-08 08:34:52 +07; 28min ago
   Main PID: 23710 (java)
      Tasks: 34 (limit: 4551)
     Memory: 236.4M (peak: 241.9M)
        CPU: 11.274s
     CGroup: /system.slice/spring-app.service
             `-23710 /usr/bin/java -jar /opt/spring-app/app.jar

Oct 08 08:34:56 halo java[23710]: 2026-10-08T08:34:56.880+07:00  INFO 23710 --- [           main] com.example.springapp.SpringApp             : Started SpringApp in 3.912 seconds (process running for 4.376)
Oct 08 08:41:19 halo java[23710]: 2026-10-08T08:41:19.377+07:00  INFO 23710 --- [nio-8082-exec-1] com.example.springapp.HealthController      : GET /health host=127.0.0.1:8082 x-real-ip=- x-forwarded-for=- x-forwarded-proto=-
Oct 08 08:41:26 halo java[23710]: 2026-10-08T08:41:26.904+07:00  INFO 23710 --- [nio-8082-exec-2] com.example.springapp.HealthController      : HEAD /health host=127.0.0.1:8082 x-real-ip=- x-forwarded-for=- x-forwarded-proto=-
```

Kiểm tra cổng 8082 và gọi trực tiếp endpoint `/health` của backend:

```bash
devops@halo:~$ sudo ss -tlnp | grep 8082
[sudo] password for devops:
LISTEN 0      100        127.0.0.1:8082       0.0.0.0:*    users:(("java",pid=23710,fd=10))
devops@halo:~$ curl -s http://127.0.0.1:8082/health; echo
{"status":"UP","app":"spring-app","version":"1.0.0"}
devops@halo:~$ curl -I http://127.0.0.1:8082/health
HTTP/1.1 200 
Content-Type: application/json
Content-Length: 52
Date: Thu, 08 Oct 2026 02:05:41 GMT
```

Nhận xét:

- `spring-app.service` ở trạng thái `active (running)`, Main PID 23710, tiến trình tên `java`.
- Cổng 8082 chỉ nghe ở `127.0.0.1` (không phải `0.0.0.0`), nên từ ngoài không gọi thẳng được.
- Backend trả `200` với `Content-Type: application/json`. Khi gọi trực tiếp, ứng dụng thấy `host=127.0.0.1:8082` và không có header `x-real-ip`; điều này sẽ khác sau khi đi qua Nginx.

## 4. Bước 2 - Tạo trang tĩnh

Thư mục `/var/www/html/` đã có sẵn, chỉ chứa trang mặc định `index.nginx-debian.html` (615 byte) do gói Nginx tạo. Tạo `index.html` bằng `sudo tee` để ghi file với quyền root mà không cần mở trình soạn thảo:

```bash
devops@halo:~$ sudo tee /var/www/html/index.html > /dev/null << 'EOF'
> (nội dung giống file index.html trong thư mục bài nộp, 51 dòng)
> EOF
devops@halo:~$ ls -la /var/www/html/
total 16
drwxr-xr-x 2 root root 4096 Oct  8 09:10 .
drwxr-xr-x 3 root root 4096 Sep 29 09:40 ..
-rw-r--r-- 1 root root 2175 Oct  8 09:10 index.html
-rw-r--r-- 1 root root  615 Sep 29 09:40 index.nginx-debian.html
devops@halo:~$ wc -c /var/www/html/index.html
2175 /var/www/html/index.html
devops@halo:~$ stat -c '%U:%G %a %s %y' /var/www/html/index.html
root:root 644 2175 2026-10-08 09:10:42.318204917 +0700
```

Trang là HTML5 hợp lệ, có `<meta charset="utf-8">` để hiển thị đúng tiếng Việt, `<meta name="viewport">` cho màn hình nhỏ và CSS nội tuyến gọn. Nội dung hiển thị Họ tên (Lê Phú Toàn), Mã lớp (PTIT-DEVOPS-2026), khóa học (PTIT DevOps Course), Session 07 - Bài 4, cùng một đoạn mô tả kiến trúc: `/` là lưu lượng tĩnh do Nginx phục vụ, `/api/` là lưu lượng động chuyển tới Spring Boot.

Về quyền: file thuộc `root:root` với mode `644`, user `www-data` (tiến trình worker của Nginx) có quyền đọc; thư mục cha `755` cho phép duyệt. Kích thước thật là 2175 byte, con số này sẽ khớp với `Content-Length` ở mục 8.

## 5. Bước 3 - Viết spring-proxy.conf

Tạo file cấu hình tại `/etc/nginx/sites-available/spring-proxy.conf`:

```bash
devops@halo:~$ sudo tee /etc/nginx/sites-available/spring-proxy.conf > /dev/null << 'EOF'
> (nội dung giống file spring-proxy.conf trong thư mục bài nộp, 56 dòng, xem mục 5)
> EOF
devops@halo:~$ ls -l /etc/nginx/sites-available/spring-proxy.conf
-rw-r--r-- 1 root root 2690 Oct  8 09:16 /etc/nginx/sites-available/spring-proxy.conf
```

Nội dung chính của file (lược bớt comment; bản đầy đủ có comment tiếng Việt cho từng khối nằm trong `spring-proxy.conf`):

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root /var/www/html;
    index index.html;

    access_log /var/log/nginx/spring-proxy.access.log;
    error_log  /var/log/nginx/spring-proxy.error.log;

    location / {
        try_files $uri $uri/ =404;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8082/;

        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 5s;
        proxy_read_timeout    60s;
    }
}
```

### 5.1 Giải thích các khối

- `listen 80 default_server;` và `listen [::]:80 default_server;`: nghe cổng 80 cho IPv4 và IPv6, nhận mọi yêu cầu không khớp `server_name` nào (ví dụ truy cập thẳng bằng IP). `server_name _;` là tên giữ chỗ.
- `root /var/www/html;` và `index index.html;`: thư mục gốc nội dung tĩnh và file chỉ mục. `access_log`, `error_log` là log riêng của site.
- `location / { try_files $uri $uri/ =404; }`: chỉ trả file có thật, ngược lại trả 404.
- `location /api/ { proxy_pass ...; }`: chuyển tiếp lưu lượng động đến Spring Boot. `proxy_connect_timeout 5s` giới hạn thời gian kết nối tới backend, `proxy_read_timeout 60s` giới hạn thời gian chờ phản hồi (quá hạn trả 504).

### 5.2 Dấu `/` cuối trong `proxy_pass`

Đây là điểm dễ sai nhất của bài. Khi `proxy_pass` có thêm phần đường dẫn (kể cả chỉ là một dấu `/`), Nginx thay phần khớp của `location` bằng phần đường dẫn đó. Khi không có phần đường dẫn, Nginx giữ nguyên URI gốc.

| Khai báo | Client gọi | Backend nhận | Kết quả với backend này |
|---|---|---|---|
| `proxy_pass http://127.0.0.1:8082/;` (có `/` cuối) | `/api/health` | `/health` | 200, đúng endpoint |
| `proxy_pass http://127.0.0.1:8082;` (không có `/` cuối) | `/api/health` | `/api/health` | 404, backend không có đường dẫn này |

Vì backend chỉ có `/health` chứ không có `/api/health`, bài dùng dạng có `/` cuối. Đây cũng là lý do mục 8 thấy backend trả lỗi 404 với `"path":"/khong-ton-tai"` (đã mất tiền tố `/api`).

### 5.3 Các header chuyển tiếp

Khi proxy, kết nối đến backend do Nginx tự mở, nên mặc định backend thấy Host là `127.0.0.1:8082` và IP nguồn là `127.0.0.1`. Các header sau trả lại thông tin của client gốc:

| Header | Giá trị | Công dụng |
|---|---|---|
| `Host` | `$host` | Backend biết client gọi bằng tên/IP nào, sinh link và redirect đúng host, hỗ trợ virtual host phía sau |
| `X-Real-IP` | `$remote_addr` | IP thật của client; log và kiểm soát truy cập ở backend không bị ghi nhầm là 127.0.0.1 |
| `X-Forwarded-For` | `$proxy_add_x_forwarded_for` | Chuỗi IP đi qua các proxy (thêm IP client vào cuối chuỗi có sẵn) |
| `X-Forwarded-Proto` | `$scheme` | Giao thức client dùng (`http` hoặc `https`), cần để backend sinh URL đúng khi có TLS termination |

Lưu ý: Spring Boot chỉ tự dùng các header này khi bật xử lý forwarded header (ví dụ `server.forward-headers-strategy`); ứng dụng của bài ghi chúng vào log để quan sát (mục 8.4).

### 5.4 `proxy_http_version 1.1`

Mặc định Nginx nói chuyện với backend bằng HTTP/1.0. HTTP/1.1 là điều kiện để dùng keep-alive với upstream và để nhận phản hồi dạng chunked (Tomcat của Spring Boot dùng chunked khi không biết trước độ dài). Bài này bật `1.1` theo gợi ý của đề; để thực sự tái sử dụng kết nối tới backend còn cần khối `upstream` có `keepalive` và `proxy_set_header Connection ""`, nằm ngoài phạm vi bài.

## 6. Bước 4 - Kích hoạt site

Nginx nạp mọi file trong `sites-enabled`. Site `my-app.conf` hiện đang giữ `default_server` cổng 80, nếu để nguyên cùng `spring-proxy.conf` (cũng khai báo `default_server`) thì `nginx -t` báo lỗi `a duplicate default server for 0.0.0.0:80`, và nếu bỏ `default_server` thì site cũ vẫn chiếm vai trò mặc định. Vì đề yêu cầu `spring-proxy.conf` tiếp quản cổng 80, cần gỡ symlink `my-app.conf` khỏi `sites-enabled`. Đây chỉ là gỡ liên kết: file gốc vẫn còn trong `sites-available`, muốn quay lại chỉ cần tạo lại symlink.

`multi-port.conf` dùng cổng 8080 và 8090 nên không xung đột và được giữ nguyên.

```bash
devops@halo:~$ sudo rm /etc/nginx/sites-enabled/my-app.conf
devops@halo:~$ ls -l /etc/nginx/sites-available/my-app.conf
-rw-r--r-- 1 root root 1300 Oct  2 15:15 /etc/nginx/sites-available/my-app.conf
devops@halo:~$ sudo ln -s /etc/nginx/sites-available/spring-proxy.conf /etc/nginx/sites-enabled/
devops@halo:~$ ls -la /etc/nginx/sites-enabled/
total 8
drwxr-xr-x 2 root root 4096 Oct  8 09:19 .
drwxr-xr-x 8 root root 4096 Sep 29 09:40 ..
lrwxrwxrwx 1 root root   42 Oct  2 14:16 multi-port.conf -> /etc/nginx/sites-available/multi-port.conf
lrwxrwxrwx 1 root root   44 Oct  8 09:19 spring-proxy.conf -> /etc/nginx/sites-available/spring-proxy.conf
```

Bước tiếp theo là kiểm tra cú pháp rồi mới reload (mục 7).

## 7. Kết quả kiểm tra cú pháp `nginx -t`

```bash
devops@halo:~$ sudo nginx -t
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

- Dòng `syntax is ok`: cú pháp tệp cấu hình hợp lệ, không có lỗi chỉ thị hay thiếu dấu `;`.
- Dòng `test is successful`: Nginx đã nạp thử toàn bộ cấu hình (kể cả các file trong `sites-enabled`), kiểm tra được các đường dẫn và mở thử các file log, không có xung đột như trùng `default_server`.

Chỉ khi cả hai dòng này xuất hiện mới reload; làm ngược lại có nguy cơ reload thất bại và để lại cấu hình hỏng:

```bash
devops@halo:~$ sudo systemctl reload nginx
devops@halo:~$ systemctl is-active nginx
active
devops@halo:~$ ps -eo user:8,pid,ppid,cmd | grep '[n]ginx'
root        1342       1 nginx: master process /usr/sbin/nginx -g daemon on; master_process on;
www-data   24598    1342 nginx: worker process
www-data   24599    1342 nginx: worker process
```

`reload` khác `restart`: master process nạp cấu hình mới, sinh worker mới (PID 24598 và 24599) rồi cho worker cũ xử lý nốt các kết nối đang dở, nên không làm gián đoạn dịch vụ.

## 8. Kết quả kiểm tra bằng curl

### 8.1 Trang tĩnh: `curl -I http://localhost/`

```bash
devops@halo:~$ curl -I http://localhost/
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
Date: Thu, 08 Oct 2026 02:23:08 GMT
Content-Type: text/html
Content-Length: 2175
Last-Modified: Thu, 08 Oct 2026 02:10:42 GMT
Connection: keep-alive
ETag: "6ac6fba2-87f"
Accept-Ranges: bytes

devops@halo:~$ curl -s http://localhost/ | grep -E "Lê Phú Toàn|PTIT-DEVOPS-2026"
      <tr><th>Họ tên</th><td>Lê Phú Toàn</td></tr>
      <tr><th>Mã lớp</th><td>PTIT-DEVOPS-2026</td></tr>
```

- `HTTP/1.1 200 OK`, `Content-Type: text/html`.
- `Content-Length: 2175` trùng kết quả `wc -c` ở mục 4.
- `ETag: "6ac6fba2-87f"` được Nginx tạo từ thời gian sửa đổi và kích thước file: `6ac6fba2` (hex) là 1791425442 giây, tức 02:10:42 GMT ngày 08/10/2026, khớp `Last-Modified`; `87f` (hex) là 2175.
- Lệnh `grep` tìm thấy hai dòng chứa họ tên và mã lớp, chứng tỏ nội dung trả về là `index.html` vừa tạo.

### 8.2 Lưu lượng động: `/api/health` qua proxy

```bash
devops@halo:~$ curl -I http://localhost/api/health
HTTP/1.1 200 
Server: nginx/1.24.0 (Ubuntu)
Date: Thu, 08 Oct 2026 02:24:05 GMT
Content-Type: application/json
Content-Length: 52
Connection: keep-alive

devops@halo:~$ curl -s http://localhost/api/health; echo
{"status":"UP","app":"spring-app","version":"1.0.0"}
devops@halo:~$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost/api/khong-ton-tai
404
devops@halo:~$ curl -s http://localhost/api/khong-ton-tai; echo
{"timestamp":"2026-10-08T02:25:34.612+00:00","status":404,"error":"Not Found","path":"/khong-ton-tai"}
devops@halo:~$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost/khong-co.html
404
```

- `HTTP/1.1 200` với `Content-Type: application/json`: phản hồi đến từ Spring Boot.
- Header `Server: nginx/1.24.0 (Ubuntu)` cho thấy phản hồi đi ra qua Nginx, client không hề biết có Spring Boot phía sau.
- `/api/health` được Nginx chuyển thành `/health` ở backend (nhờ dấu `/` cuối của `proxy_pass`). Bản thân endpoint `/api/health` không tồn tại ở backend.
- `/api/khong-ton-tai` trả 404 từ chính Spring Boot, không phải từ Nginx. Spring Boot trả JSON lỗi mặc định gồm `timestamp`, `status`, `error`, `path`; trường `path` là `/khong-ton-tai`, xác nhận tiền tố `/api` đã bị cắt trước khi đến backend. Đây không phải 502: kết nối đến backend vẫn thành công, backend chỉ trả mã trạng thái tương ứng của nó.
- `/khong-co.html` trả 404 từ Nginx (khối `location /` với `try_files ... =404`), kích thước trang lỗi 162 byte.

### 8.3 Từ máy cá nhân qua IP công cộng

```bash
$ curl -I http://103.116.104.228/
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
Date: Thu, 08 Oct 2026 02:28:15 GMT
Content-Type: text/html
Content-Length: 2175
Last-Modified: Thu, 08 Oct 2026 02:10:42 GMT
Connection: keep-alive
ETag: "6ac6fba2-87f"
Accept-Ranges: bytes

$ curl -s http://103.116.104.228/api/health; echo
{"status":"UP","app":"spring-app","version":"1.0.0"}
$ curl -I http://103.116.104.228/api/health
HTTP/1.1 200 
Server: nginx/1.24.0 (Ubuntu)
Date: Thu, 08 Oct 2026 02:29:05 GMT
Content-Type: application/json
Content-Length: 52
Connection: keep-alive

$ curl -m 5 http://103.116.104.228:8082/health
curl: (28) Connection timed out after 5002 milliseconds
```

Dòng cuối là thử truy cập thẳng cổng 8082 của backend: cổng 80 truy cập được bình thường, còn cổng 8082 không với tới được từ bên ngoài (UFW không mở, và Spring Boot chỉ nghe ở `127.0.0.1`): toàn bộ lưu lượng vào backend bắt buộc đi qua Nginx.

### 8.4 Access log của Nginx và log của backend

```bash
devops@halo:~$ sudo tail -n 10 /var/log/nginx/spring-proxy.access.log
127.0.0.1 - - [08/Oct/2026:09:23:08 +0700] "HEAD / HTTP/1.1" 200 0 "-" "curl/8.5.0"
127.0.0.1 - - [08/Oct/2026:09:23:31 +0700] "GET / HTTP/1.1" 200 2175 "-" "curl/8.5.0"
127.0.0.1 - - [08/Oct/2026:09:24:05 +0700] "HEAD /api/health HTTP/1.1" 200 0 "-" "curl/8.5.0"
127.0.0.1 - - [08/Oct/2026:09:24:29 +0700] "GET /api/health HTTP/1.1" 200 52 "-" "curl/8.5.0"
127.0.0.1 - - [08/Oct/2026:09:25:10 +0700] "GET /api/khong-ton-tai HTTP/1.1" 404 102 "-" "curl/8.5.0"
127.0.0.1 - - [08/Oct/2026:09:25:34 +0700] "GET /api/khong-ton-tai HTTP/1.1" 404 102 "-" "curl/8.5.0"
127.0.0.1 - - [08/Oct/2026:09:26:02 +0700] "GET /khong-co.html HTTP/1.1" 404 162 "-" "curl/8.5.0"
113.161.72.19 - - [08/Oct/2026:09:28:15 +0700] "HEAD / HTTP/1.1" 200 0 "-" "curl/8.15.0"
113.161.72.19 - - [08/Oct/2026:09:28:40 +0700] "GET /api/health HTTP/1.1" 200 52 "-" "curl/8.15.0"
113.161.72.19 - - [08/Oct/2026:09:29:05 +0700] "HEAD /api/health HTTP/1.1" 200 0 "-" "curl/8.15.0"
```

Mỗi dòng theo định dạng `combined`: IP client, thời gian, dòng yêu cầu, mã trạng thái, số byte thân phản hồi (yêu cầu `HEAD` luôn là 0), referer, user agent. Các yêu cầu trên máy chủ đến từ `127.0.0.1` (curl 8.5.0), các yêu cầu từ máy cá nhân đến từ `113.161.72.19` (curl 8.15.0).

Log của backend cho thấy tác dụng của các header chuyển tiếp:

```bash
devops@halo:~$ journalctl -u spring-app.service -n 3 --no-pager
Oct 08 09:24:29 halo java[23710]: 2026-10-08T09:24:29.517+07:00  INFO 23710 --- [nio-8082-exec-5] com.example.springapp.HealthController      : GET /health host=localhost x-real-ip=127.0.0.1 x-forwarded-for=127.0.0.1 x-forwarded-proto=http
Oct 08 09:28:40 halo java[23710]: 2026-10-08T09:28:40.263+07:00  INFO 23710 --- [nio-8082-exec-6] com.example.springapp.HealthController      : GET /health host=103.116.104.228 x-real-ip=113.161.72.19 x-forwarded-for=113.161.72.19 x-forwarded-proto=http
Oct 08 09:29:05 halo java[23710]: 2026-10-08T09:29:05.748+07:00  INFO 23710 --- [nio-8082-exec-7] com.example.springapp.HealthController      : HEAD /health host=103.116.104.228 x-real-ip=113.161.72.19 x-forwarded-for=113.161.72.19 x-forwarded-proto=http
```

- Yêu cầu từ máy chủ: `host=localhost`, `x-real-ip=127.0.0.1`.
- Yêu cầu từ máy cá nhân: `host=103.116.104.228` và `x-real-ip=113.161.72.19`, tức backend thấy đúng địa chỉ của client thật dù kết nối vật lý đến từ Nginx (`127.0.0.1`).
- Khi gọi thẳng vào backend ở mục 3, hai giá trị này là `127.0.0.1:8082` và `-` (không có header).
- Yêu cầu `HEAD /` và `GET /api/khong-ton-tai` không có dòng log ở đây: trang tĩnh do Nginx xử lý, còn đường dẫn không tồn tại không đi qua `HealthController`.

## 9. Minh họa lỗi 502 Bad Gateway

502 xuất hiện khi Nginx nhận được yêu cầu hợp lệ nhưng không lấy được phản hồi hợp lệ từ upstream. Dừng backend để tái hiện, rồi khởi động lại:

```bash
devops@halo:~$ sudo systemctl stop spring-app.service
devops@halo:~$ systemctl is-active spring-app.service
inactive
devops@halo:~$ sudo ss -tlnp | grep 8082; echo "exit=$?"
exit=1
devops@halo:~$ curl -I http://localhost/api/health
HTTP/1.1 502 Bad Gateway
Server: nginx/1.24.0 (Ubuntu)
Date: Thu, 08 Oct 2026 02:33:47 GMT
Content-Type: text/html
Content-Length: 166
Connection: keep-alive

devops@halo:~$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost/
200
```

Nhận xét:

- Trang tĩnh `/` vẫn trả 200: Nginx không phụ thuộc backend ở khối `location /`.
- Yêu cầu `/api/health` trả `502 Bad Gateway`; thân phản hồi là trang lỗi mặc định của Nginx (166 byte).

Lý do nằm ở error log (hai dòng ứng với hai yêu cầu bị 502: HEAD lúc 09:33:47 và GET lúc 09:34:20, lệnh GET có trong `terminal_log.txt`):

```bash
devops@halo:~$ sudo tail -n 2 /var/log/nginx/spring-proxy.error.log
2026/10/08 09:33:47 [error] 24599#24599: *11 connect() failed (111: Connection refused) while connecting to upstream, client: 127.0.0.1, server: _, request: "HEAD /api/health HTTP/1.1", upstream: "http://127.0.0.1:8082/health", host: "localhost"
2026/10/08 09:34:20 [error] 24599#24599: *13 connect() failed (111: Connection refused) while connecting to upstream, client: 127.0.0.1, server: _, request: "GET /api/health HTTP/1.1", upstream: "http://127.0.0.1:8082/health", host: "localhost"
```

`connect() failed (111: Connection refused) while connecting to upstream` nghĩa là không có tiến trình nào nghe ở `127.0.0.1:8082`, hệ điều hành từ chối kết nối ngay lập tức. Dòng log ghi rõ `upstream: "http://127.0.0.1:8082/health"` (đã bỏ tiền tố `/api`).

Khởi động lại backend:

```bash
devops@halo:~$ sudo systemctl start spring-app.service
devops@halo:~$ systemctl is-active spring-app.service
active
devops@halo:~$ curl -sI http://localhost/api/health | head -n 1
HTTP/1.1 502 Bad Gateway
devops@halo:~$ sleep 6; curl -sI http://localhost/api/health | head -n 1
HTTP/1.1 200 
devops@halo:~$ systemctl show spring-app.service -p MainPID
MainPID=24735
devops@halo:~$ journalctl -u spring-app.service -n 3 --no-pager
Oct 08 09:35:06 halo java[24735]: 2026-10-08T09:35:06.214+07:00  INFO 24735 --- [           main] o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat started on port 8082 (http) with context path '/'
Oct 08 09:35:06 halo java[24735]: 2026-10-08T09:35:06.287+07:00  INFO 24735 --- [           main] com.example.springapp.SpringApp             : Started SpringApp in 3.847 seconds (process running for 4.301)
Oct 08 09:35:13 halo java[24735]: 2026-10-08T09:35:13.062+07:00  INFO 24735 --- [nio-8082-exec-1] com.example.springapp.HealthController      : HEAD /health host=localhost x-real-ip=127.0.0.1 x-forwarded-for=127.0.0.1 x-forwarded-proto=http
```

Lệnh `start` trả về ngay nhưng JVM cần khoảng 4 giây để Tomcat nghe cổng (log ghi `Started SpringApp in 3.847 seconds`), nên yêu cầu gọi sát sau đó vẫn bị 502. Chờ vài giây rồi gọi lại thì trả `200`; dịch vụ có Main PID mới 24735.

Các nguyên nhân 502 thường gặp:

- Backend chưa chạy hoặc đã dừng (trường hợp vừa mô phỏng), hoặc đang khởi động lại.
- `proxy_pass` trỏ sai địa chỉ hay cổng so với cấu hình thật của ứng dụng (ví dụ ứng dụng nghe 8082 mà proxy trỏ 8080).
- Backend trả phản hồi không đúng chuẩn HTTP, hoặc nhầm giao thức (ví dụ backend chạy HTTPS nhưng `proxy_pass` dùng `http://`), hoặc header phản hồi quá lớn so với bộ đệm của Nginx.
- Cách chẩn đoán nhanh: xem `error_log` của Nginx, rồi `curl` thẳng vào `127.0.0.1:8082` để biết lỗi nằm ở Nginx hay backend.

## 10. Script triển khai tự động `deploy_proxy.sh`

Toàn bộ các bước trên được gói trong một script bash (`set -euo pipefail`, comment tiếng Việt):

1. Kiểm tra quyền root và có sẵn `nginx`, `curl`, hai file nguồn.
2. Cài `index.html` và `spring-proxy.conf` bằng `install` (root:root, 644). File giống bản đang dùng thì bỏ qua; khác thì sao lưu vào `/var/backups/nginx-spring-proxy` trước khi ghi đè.
3. Gỡ symlink các site cũ có thể chiếm `default_server` (`my-app.conf`, `default`); chỉ gỡ liên kết, giữ file gốc.
4. Tạo symlink `spring-proxy.conf` trong `sites-enabled` nếu chưa có hoặc chưa đúng.
5. Chạy `nginx -t`; chỉ `reload` khi hợp lệ, nếu lỗi thì khôi phục symlink và cấu hình cũ rồi thoát với mã lỗi.
6. Kiểm tra nhanh bằng curl và cảnh báo nếu backend chưa phản hồi (502).

Script là idempotent: chạy lại nhiều lần không thay đổi trạng thái khi mọi thứ đã đúng. Sau khi cấu hình xong, ba file được sao chép lên `~/ex4` trên máy chủ bằng `scp` và script được chạy thử bằng `sudo ./deploy_proxy.sh` (trước đó đã `bash -n` và `diff -q` xác nhận file nguồn giống bản đang chạy). Các bước cài file, gỡ site cũ và tạo symlink đều báo `BO QUA` vì đã đúng từ trước, `nginx -t` thành công, hai yêu cầu kiểm tra trả 200:

```bash
devops@halo:~/ex4$ sudo ./deploy_proxy.sh
[BO QUA] /var/www/html/index.html giống bản đang dùng
[BO QUA] /etc/nginx/sites-available/spring-proxy.conf giống bản đang dùng
[BO QUA] my-app.conf không được kích hoạt
[BO QUA] default không được kích hoạt
[BO QUA] symlink /etc/nginx/sites-enabled/spring-proxy.conf đã trỏ đúng
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
[OK] nginx -t thành công
[RELOAD] nginx: active
[KIEM TRA] GET /          -> HTTP 200
[KIEM TRA] GET /api/health -> HTTP 200
[XONG] Triển khai hoàn tất
```

## 11. Bảng xử lý sự cố

| Hiện tượng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `nginx: [emerg] a duplicate default server for 0.0.0.0:80 in /etc/nginx/sites-enabled/spring-proxy.conf:12` | Hai site cùng khai báo `default_server` cho cổng 80 (ở đây là `my-app.conf` còn được kích hoạt) | Gỡ symlink site cũ: `sudo rm /etc/nginx/sites-enabled/my-app.conf`, rồi `nginx -t` lại |
| `502 Bad Gateway` | Backend dừng, sai cổng, bind địa chỉ khác, đang khởi động | Xem `/var/log/nginx/spring-proxy.error.log`, `systemctl status spring-app.service`, `ss -tlnp \| grep 8082`, khởi động lại dịch vụ |
| `504 Gateway Timeout` | Backend xử lý quá `proxy_read_timeout` (60s) | Tìm nguyên nhân chậm ở backend, hoặc nâng timeout cho đường dẫn cụ thể |
| `/api/health` trả 404 từ backend (JSON có `"path":"/api/health"`) | `proxy_pass` thiếu dấu `/` cuối nên backend nhận nguyên `/api/health` | Sửa thành `proxy_pass http://127.0.0.1:8082/;`, `nginx -t`, reload |
| `403 Forbidden` ở trang tĩnh | `www-data` không đọc được file hoặc không duyệt được thư mục cha; hoặc thiếu `index.html` mà không bật `autoindex` | `sudo chmod 644 /var/www/html/index.html`, thư mục `755`; kiểm tra `namei -l /var/www/html/index.html` |
| Backend thấy Host là `127.0.0.1:8082`, IP client là `127.0.0.1` | Thiếu `proxy_set_header Host $host` và `X-Real-IP` | Thêm các header ở mục 5.3, reload |
| Sửa cấu hình nhưng không có tác dụng | Chưa tạo symlink, chưa `reload`, hoặc sửa nhầm file | `ls -l /etc/nginx/sites-enabled/`, `nginx -t`, `systemctl reload nginx` |

## 12. Ghi chú bảo mật

- Backend chỉ bind `127.0.0.1` (`server.address=127.0.0.1`), nên dù ai đó mở nhầm cổng thì kết nối từ ngoài vẫn bị từ chối. UFW cũng không mở cổng 8082 (chỉ 2222, 80, 8080, 8090), đúng nguyên tắc nhiều lớp bảo vệ.
- `/var/www/html` thuộc `root:root`, mode 644: Nginx chỉ cần quyền đọc, tiến trình web không ghi đè được nội dung tĩnh.
- Header `X-Real-IP` và `X-Forwarded-For` có thể bị client giả mạo nếu backend nhận trực tiếp từ Internet. Vì backend chỉ nhận từ Nginx (`127.0.0.1`), và `$proxy_add_x_forwarded_for` luôn nối IP kết nối thật, rủi ro này được kiểm soát.
- Nên làm tiếp: bật HTTPS (TLS termination) trên Nginx và đặt `server_tokens off;` để ẩn phiên bản.

## 13. Đối chiếu yêu cầu đề bài

| Yêu cầu | Thực hiện | Mục |
|---|---|---|
| Tạo thư mục trang tĩnh `/var/www/html/` và `index.html` hiển thị Họ tên, Mã lớp | `index.html` có Lê Phú Toàn, PTIT-DEVOPS-2026, 2175 byte | 4 |
| Tạo `/etc/nginx/sites-available/spring-proxy.conf` | Đã tạo, 56 dòng, 2690 byte | 5 |
| `/` phục vụ tĩnh từ `/var/www/html/` | `root /var/www/html;` và `location /` | 5, 8.1 |
| `/api/` `proxy_pass` đến `http://127.0.0.1:8082/` | `location /api/` với `proxy_pass http://127.0.0.1:8082/;` | 5.2, 8.2 |
| `proxy_set_header Host $host`, `X-Real-IP $remote_addr` | Có, kèm `X-Forwarded-For` và `X-Forwarded-Proto` | 5.3, 8.4 |
| Kích hoạt bằng symlink vào `sites-enabled` | `ln -s` (sau khi gỡ symlink site cũ `my-app.conf`) | 6 |
| `nginx -t` thành công trước khi reload | `syntax is ok` và `test is successful` | 7 |
| `curl -I http://localhost/` trả 200 kèm nội dung tĩnh | 200, Content-Length 2175, grep thấy họ tên và mã lớp | 8.1 |
| `/api/health` trả mã tương ứng của backend, không 502 | 200 JSON; mã 404 của backend được giữ nguyên | 8.2 |
| Báo cáo `nginx -t` và kết quả curl | Mục 7 và mục 8 | 7, 8 |

## 14. Kết luận

Nginx đã được cấu hình làm Reverse Proxy tại cổng 80 cho hệ thống: lưu lượng tĩnh ở `/` được phục vụ trực tiếp từ `/var/www/html/`, mọi yêu cầu bắt đầu bằng `/api/` được chuyển tiếp đến Spring Boot ở `127.0.0.1:8082` với tiền tố `/api` được cắt bỏ nhờ dấu `/` cuối trong `proxy_pass`. Các header `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto` giúp backend nhìn thấy thông tin thật của client. Quy trình kích hoạt tuân theo thứ tự an toàn: gỡ site cũ chiếm `default_server`, tạo symlink, `nginx -t` rồi mới `reload`.

Hai điểm cần nhớ khi vận hành: dấu `/` cuối trong `proxy_pass` quyết định URI mà backend nhận (nguồn lỗi 404 phổ biến), và lỗi 502 để lại dấu vết `Connection refused` trong `error_log` khi backend dừng. Giữ backend chỉ nghe ở `127.0.0.1` và không mở cổng trên UFW biến Nginx thành cửa ngõ duy nhất vào ứng dụng.
