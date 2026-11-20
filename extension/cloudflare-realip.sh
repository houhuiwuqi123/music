#!/usr/bin/env bash
# 宝塔 nginx：只对指定站点，在经 Cloudflare 代理（橙云）时还原访客真实 IP。
#
#   sudo ./extension/cloudflare-realip.sh install [域名]   生成配置、检查语法并重载 nginx（重复执行即更新 IP 段）
#   sudo ./extension/cloudflare-realip.sh cron [域名]      另外每周自动更新一次 Cloudflare IP 段
#   sudo ./extension/cloudflare-realip.sh remove [域名]    删除配置（和定时任务）并重载 nginx
#        ./extension/cloudflare-realip.sh status [域名]    查看是否生效
#   域名默认 music.webtrc.eu.cc，也可用环境变量 SITE 指定。
#
# 原理：橙云回源时连到 nginx 的是 Cloudflare 边缘节点，$remote_addr 是 CF 的 IP。本脚本只在该站点的
# server {} 里写入 set_real_ip_from <CF 段> + real_ip_header CF-Connecting-IP：只有来自 CF 的请求才采信
# 这个头，本站点的 $remote_addr、访问日志、limit_req 和转给后端的 X-Forwarded-For 都变成访客 IP。
#
# 只影响这一个站点：配置放在宝塔的站点扩展目录 vhost/nginx/extension/<域名>/，由该站点 server {} 里的
#   include /www/server/panel/vhost/nginx/extension/<域名>/*.conf;
# 引入（宝塔新建站点时自带这一行；没有的话脚本会在 server_name 后面补上，并做标记以便 remove 时删除）。
# 不写 http 级配置，服务器上的其他站点（无论是否开了 Cloudflare）完全不受影响。
#
# 环境变量：NGINX_BIN（默认 /www/server/nginx/sbin/nginx）、VHOST_DIR（默认 /www/server/panel/vhost/nginx）
set -euo pipefail

SITE="${2:-${SITE:-music.webtrc.eu.cc}}"
NGINX_BIN="${NGINX_BIN:-/www/server/nginx/sbin/nginx}"
VHOST_DIR="${VHOST_DIR:-/www/server/panel/vhost/nginx}"
SITE_CONF="$VHOST_DIR/$SITE.conf"
EXT_DIR="$VHOST_DIR/extension/$SITE"
CONF="$EXT_DIR/cloudflare_realip.conf"
INCLUDE_LINE="include $EXT_DIR/*.conf;"
MARK="# added by cloudflare-realip.sh"
CRON_FILE="/etc/cron.d/cloudflare-realip-${SITE//./-}"
LEGACY_CONF="$VHOST_DIR/0.cloudflare_realip.conf" # 旧版写在 http 级别，会影响所有站点，安装时清理
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# 官方列表取不到时使用（https://www.cloudflare.com/ips/）
FALLBACK_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
FALLBACK_V6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
2a06:98c0::/29 2c0f:f248::/32"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }
root() { [ "$(id -u)" -eq 0 ] || die "此操作需要 root（sudo $0 $1 $SITE）"; }

[[ "$SITE" =~ ^[A-Za-z0-9.-]+$ ]] || die "域名不合法：$SITE"

preflight() {
  [ -x "$NGINX_BIN" ] || die "找不到 nginx：$NGINX_BIN（不是宝塔默认路径时用 NGINX_BIN=… 指定）"
  [ -f "$SITE_CONF" ] || die "找不到站点配置 $SITE_CONF（先在宝塔添加站点 $SITE，或用 install <域名> 指定）"
  "$NGINX_BIN" -V 2>&1 | grep -q -- '--with-http_realip_module' \
    || die "当前 nginx 没有编译 http_realip_module。宝塔：软件商店 → Nginx → 设置 → 切换/重装版本（默认版本都带此模块）"
}

has_include() { grep -qF "extension/$SITE/" "$SITE_CONF"; }

# 下载一份列表，只保留合法 CIDR；失败时输出为空
fetch() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS --max-time 10 "$1" 2>/dev/null | tr -d '\r' | grep -E "$2" || true
}

reload_nginx() {
  "$NGINX_BIN" -t || return 1
  if [ -x /etc/init.d/nginx ]; then /etc/init.d/nginx reload >/dev/null; else "$NGINX_BIN" -s reload; fi
  info "nginx 已重载"
}

cmd_install() {
  root install
  preflight
  local v4 v6 source="Cloudflare 官方列表"
  v4="$(fetch https://www.cloudflare.com/ips-v4 '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$')"
  v6="$(fetch https://www.cloudflare.com/ips-v6 '^[0-9a-fA-F:]+/[0-9]{1,3}$')"
  if [ -z "$v4" ] || [ -z "$v6" ]; then
    warn "无法从 cloudflare.com 获取 IP 段，使用脚本内置列表"
    v4="$FALLBACK_V4"; v6="$FALLBACK_V6"; source="脚本内置列表"
  fi

  local tmp
  tmp="$(mktemp)"
  {
    echo "# 由 $SCRIPT 生成于 $(date '+%F %T')（$source），请勿手改，重新执行 install 即可更新。"
    echo "# 仅作用于站点 $SITE：经 Cloudflare 代理的请求，\$remote_addr 还原为 CF-Connecting-IP（访客真实 IP）。"
    for cidr in $v4 $v6; do echo "set_real_ip_from $cidr;"; done
    echo "real_ip_header CF-Connecting-IP;"
  } > "$tmp"

  if [ -f "$CONF" ] && has_include && [ ! -f "$LEGACY_CONF" ] \
    && cmp -s <(grep -v '^#' "$tmp") <(grep -v '^#' "$CONF"); then
    rm -f "$tmp"
    info "IP 段没有变化：$CONF"
    return 0
  fi

  # 备份，nginx -t 不通过时整体回滚
  local backup_dir
  backup_dir="$(mktemp -d)"
  cp -p "$SITE_CONF" "$backup_dir/site.conf"
  [ -f "$CONF" ] && cp -p "$CONF" "$backup_dir/realip.conf"
  [ -f "$LEGACY_CONF" ] && cp -p "$LEGACY_CONF" "$backup_dir/legacy.conf"

  install -d -m 755 "$EXT_DIR"
  install -m 644 "$tmp" "$CONF"
  rm -f "$tmp"
  rm -f "$LEGACY_CONF"
  if ! has_include; then
    # 在每个 server_name 含本域名的 server {} 里，server_name 那一行后面补上 include
    awk -v site="$SITE" -v line="    $INCLUDE_LINE $MARK" '
      { print }
      $1 == "server_name" { for (i = 2; i <= NF; i++) { d = $i; sub(/;$/, "", d); if (d == site) { print line; break } } }
    ' "$backup_dir/site.conf" > "$SITE_CONF.tmp"
    cat "$SITE_CONF.tmp" > "$SITE_CONF" # 保留原文件的属主和权限
    rm -f "$SITE_CONF.tmp"
    has_include || { cp -p "$backup_dir/site.conf" "$SITE_CONF"; rm -f "$CONF"; rm -rf "$backup_dir";
      die "$SITE_CONF 里没找到 server_name $SITE，无法自动添加 include。请在该站点 server {} 里手动加一行：$INCLUDE_LINE"; }
    info "已在 $SITE_CONF 中添加：$INCLUDE_LINE"
  fi

  if reload_nginx; then
    rm -rf "$backup_dir"
    info "已写入 $CONF（$(grep -c '^set_real_ip_from' "$CONF") 个 Cloudflare 段，来源：$source），只作用于 $SITE"
  else
    cp -p "$backup_dir/site.conf" "$SITE_CONF"
    if [ -f "$backup_dir/realip.conf" ]; then cp -p "$backup_dir/realip.conf" "$CONF"; else rm -f "$CONF"; fi
    if [ -f "$backup_dir/legacy.conf" ]; then cp -p "$backup_dir/legacy.conf" "$LEGACY_CONF"; fi
    rm -rf "$backup_dir"
    die "nginx -t 未通过，已回滚。若提示 real_ip_header is duplicate，说明 $SITE 的 server {} 里已有同类配置，删掉后重试"
  fi
}

cmd_cron() {
  root cron
  cmd_install
  # 每周一 04:17 更新；IP 段没变化时不会重载 nginx
  printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n17 4 * * 1 root %q install %q >/dev/null 2>&1\n' \
    "$SCRIPT" "$SITE" > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  info "已添加定时任务 $CRON_FILE（每周一 04:17 更新 Cloudflare IP 段）"
}

cmd_remove() {
  root remove
  rm -f "$CRON_FILE"
  local changed=0
  if [ -f "$CONF" ]; then rm -f "$CONF"; changed=1; fi
  if [ -f "$SITE_CONF" ] && grep -qF "$MARK" "$SITE_CONF"; then
    grep -vF "$MARK" "$SITE_CONF" > "$SITE_CONF.tmp"
    cat "$SITE_CONF.tmp" > "$SITE_CONF"
    rm -f "$SITE_CONF.tmp"
    changed=1
  fi
  if [ -f "$LEGACY_CONF" ]; then rm -f "$LEGACY_CONF"; changed=1; fi
  if [ "$changed" -eq 1 ]; then
    reload_nginx || die "删除后 nginx -t 未通过，请检查配置"
    info "已移除 $SITE 的 Cloudflare 真实 IP 配置"
  else
    info "未安装，无需删除"
  fi
}

cmd_status() {
  info "站点：$SITE"
  if [ -f "$CONF" ]; then
    echo "  配置：$CONF"
    echo "  $(head -n 1 "$CONF" | sed 's/^# //')"
    echo "  $(grep -c '^set_real_ip_from' "$CONF") 个 Cloudflare 段，real_ip_header $(grep -o 'real_ip_header [^;]*' "$CONF" | awk '{print $2}')"
  else
    warn "未安装（sudo $0 install $SITE）"
  fi
  if [ -f "$SITE_CONF" ]; then
    has_include && echo "  站点配置已 include $EXT_DIR/*.conf" || warn "$SITE_CONF 没有 include 扩展目录，配置不会生效"
  fi
  [ -f "$LEGACY_CONF" ] && warn "发现旧版全局配置 $LEGACY_CONF（影响所有站点），重新执行 install 会清理它"
  [ -f "$CRON_FILE" ] && echo "  定时更新：已开启（$CRON_FILE）" || echo "  定时更新：未开启（sudo $0 cron $SITE）"
  echo "验证：开启橙云后用浏览器打开 https://$SITE/api/whoami，应显示你所在的地区而不是 CF 机房；"
  echo "      或看站点访问日志，第一列应是访客 IP 而不是 172.64.x / 162.158.x 等 CF 段。"
}

case "${1:-}" in
  install|update) cmd_install ;;
  cron) cmd_cron ;;
  remove|uninstall) cmd_remove ;;
  status) cmd_status ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
