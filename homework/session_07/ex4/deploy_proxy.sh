#!/usr/bin/env bash
# deploy_proxy.sh - Triển khai Nginx Reverse Proxy cho ứng dụng Spring Boot (Session 07 - Bài 4).
#
# Công việc của script:
#   1. Cài index.html vào /var/www/html/ và spring-proxy.conf vào /etc/nginx/sites-available/.
#   2. Gỡ symlink của các site đang chiếm default_server cổng 80 (my-app.conf, default).
#   3. Tạo symlink spring-proxy.conf trong sites-enabled.
#   4. Chạy nginx -t; chỉ reload khi cú pháp hợp lệ, nếu lỗi thì khôi phục trạng thái cũ.
#   5. Kiểm tra nhanh bằng curl.
#
# Script idempotent: chạy lại nhiều lần cho cùng kết quả, file giống bản đang dùng thì bỏ qua,
# file khác bản đang dùng thì sao lưu vào /var/backups/nginx-spring-proxy trước khi ghi đè.
#
# Cách dùng:  sudo ./deploy_proxy.sh   (đặt cạnh index.html và spring-proxy.conf)

set -euo pipefail

# ---------------------------------------------------------------------------
# Cấu hình
# ---------------------------------------------------------------------------
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_ROOT="/var/www/html"
SITE_NAME="spring-proxy.conf"
AVAILABLE="/etc/nginx/sites-available"
ENABLED="/etc/nginx/sites-enabled"
BACKUP_DIR="/var/backups/nginx-spring-proxy"
# Các site cũ có thể chiếm default_server trên cổng 80 (chỉ gỡ symlink, giữ file gốc).
CONFLICT_SITES=("my-app.conf" "default")
STAMP="$(date +%Y%m%d-%H%M%S)"

REMOVED_LINKS=()      # các symlink đã gỡ, dùng để khôi phục nếu nginx -t lỗi
LINK_WAS_PRESENT=0    # symlink spring-proxy.conf đã có từ trước hay chưa
CONF_BACKUP=""        # đường dẫn bản sao lưu spring-proxy.conf (nếu có)

log()  { printf '[%s] %s\n' "$1" "$2"; }
die()  { log "LOI" "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Bước 0: Kiểm tra điều kiện chạy
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Cần quyền root, hãy chạy: sudo $0"
command -v nginx >/dev/null 2>&1 || die "Chưa cài nginx"
command -v curl  >/dev/null 2>&1 || die "Chưa cài curl"
[ -f "$SRC_DIR/index.html" ]      || die "Thiếu file $SRC_DIR/index.html"
[ -f "$SRC_DIR/$SITE_NAME" ]      || die "Thiếu file $SRC_DIR/$SITE_NAME"
mkdir -p "$BACKUP_DIR" "$WEB_ROOT"

# ---------------------------------------------------------------------------
# Hàm cài file: bỏ qua nếu giống bản đang dùng, sao lưu nếu khác
# Tham số: <file nguồn> <file đích> <quyền>
# Kết quả: đặt biến LAST_BACKUP nếu có sao lưu
# ---------------------------------------------------------------------------
install_file() {
    local src="$1" dst="$2" mode="$3"
    LAST_BACKUP=""
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        log "BO QUA" "$dst giống bản đang dùng"
        return 0
    fi
    if [ -f "$dst" ]; then
        LAST_BACKUP="$BACKUP_DIR/$(basename "$dst").$STAMP"
        cp -p "$dst" "$LAST_BACKUP"
        log "SAO LUU" "$dst -> $LAST_BACKUP"
    fi
    install -o root -g root -m "$mode" "$src" "$dst"
    log "CAI" "$dst ($(stat -c %s "$dst") byte)"
}

# ---------------------------------------------------------------------------
# Bước 1: Cài trang tĩnh và file cấu hình
# ---------------------------------------------------------------------------
install_file "$SRC_DIR/index.html" "$WEB_ROOT/index.html" 644
install_file "$SRC_DIR/$SITE_NAME" "$AVAILABLE/$SITE_NAME" 644
CONF_BACKUP="$LAST_BACKUP"

# ---------------------------------------------------------------------------
# Bước 2: Gỡ symlink của các site cũ chiếm default_server cổng 80
# ---------------------------------------------------------------------------
for site in "${CONFLICT_SITES[@]}"; do
    if [ -L "$ENABLED/$site" ]; then
        REMOVED_LINKS+=("$site|$(readlink "$ENABLED/$site")")
        rm "$ENABLED/$site"
        log "GO" "symlink $ENABLED/$site (file gốc vẫn còn trong sites-available)"
    else
        log "BO QUA" "$site không được kích hoạt"
    fi
done

# ---------------------------------------------------------------------------
# Bước 3: Kích hoạt site bằng symlink
# ---------------------------------------------------------------------------
if [ -L "$ENABLED/$SITE_NAME" ]; then
    LINK_WAS_PRESENT=1
fi
if [ "$(readlink "$ENABLED/$SITE_NAME" 2>/dev/null || true)" = "$AVAILABLE/$SITE_NAME" ]; then
    log "BO QUA" "symlink $ENABLED/$SITE_NAME đã trỏ đúng"
else
    ln -sfn "$AVAILABLE/$SITE_NAME" "$ENABLED/$SITE_NAME"
    log "KICH HOAT" "$ENABLED/$SITE_NAME -> $AVAILABLE/$SITE_NAME"
fi

# ---------------------------------------------------------------------------
# Bước 4: Kiểm tra cú pháp trước khi reload, lỗi thì khôi phục
# ---------------------------------------------------------------------------
rollback() {
    log "KHOI PHUC" "nginx -t lỗi, đưa cấu hình về trạng thái trước khi chạy script"
    if [ "$LINK_WAS_PRESENT" -eq 0 ]; then
        rm -f "$ENABLED/$SITE_NAME"
    fi
    if [ -n "$CONF_BACKUP" ] && [ -f "$CONF_BACKUP" ]; then
        cp -p "$CONF_BACKUP" "$AVAILABLE/$SITE_NAME"
    fi
    local item name target
    for item in "${REMOVED_LINKS[@]+"${REMOVED_LINKS[@]}"}"; do
        name="${item%%|*}"
        target="${item#*|}"
        ln -sfn "$target" "$ENABLED/$name"
    done
}

if nginx -t; then
    log "OK" "nginx -t thành công"
else
    rollback
    die "Cấu hình Nginx không hợp lệ, chưa reload"
fi

# ---------------------------------------------------------------------------
# Bước 5: Reload (không làm gián đoạn kết nối đang xử lý)
# ---------------------------------------------------------------------------
systemctl reload nginx
log "RELOAD" "nginx: $(systemctl is-active nginx)"

# ---------------------------------------------------------------------------
# Bước 6: Kiểm tra nhanh bằng curl
# ---------------------------------------------------------------------------
code_static="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true)"
code_api="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/api/health || true)"
log "KIEM TRA" "GET /          -> HTTP $code_static"
log "KIEM TRA" "GET /api/health -> HTTP $code_api"

[ "$code_static" = "200" ] || die "Trang tĩnh không trả 200"
if [ "$code_api" = "502" ] || [ "$code_api" = "000" ]; then
    log "CANH BAO" "Backend chưa phản hồi (kiểm tra: systemctl status spring-app.service)"
fi
log "XONG" "Triển khai hoàn tất"
