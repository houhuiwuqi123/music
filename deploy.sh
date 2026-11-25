#!/usr/bin/env bash
# AURU 轻量级 DHT 节点 + Candy 广场网页：编译、安装、服务管理。
#
#   ./deploy.sh build [all|backend|web]   编译（默认 all）
#   ./deploy.sh install                   编译并安装：二进制、网页、systemd 服务；若服务在运行则重启
#   ./deploy.sh start | stop | restart    控制 systemd 服务
#   ./deploy.sh status                    服务状态 + 监听端口
#   ./deploy.sh logs [行数]               跟踪日志（默认最近 100 行）
#   ./deploy.sh check                     自检：本机 API、bootstrap 列表、端口、GeoIP 文件
#
# 环境变量：APP_DIR（安装目录，默认 /www/wwwroot/webtrc）、SERVICE（默认 webtrc）
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-/www/wwwroot/webtrc}"
SERVICE="${SERVICE:-webtrc}"
UNIT_SRC="$REPO_DIR/backend/webtrc.service"
UNIT_DST="/etc/systemd/system/${SERVICE}.service"
BIN="$APP_DIR/backend/server"
HTTP_ADDR="127.0.0.1:8003"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1 —— $2"; }
root() { [ "$(id -u)" -eq 0 ] || die "此操作需要 root（sudo ./deploy.sh $*）"; }

build_backend() {
  need go "请安装 Go（go.mod 要求 1.27.2+；GOTOOLCHAIN=auto 时会自动下载对应版本）"
  info "编译节点 → backend/server.build"
  (cd "$REPO_DIR/backend" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o server.build .)
}

# nvm 只在交互 shell 里把 node 加进 PATH，sudo 还会把 PATH 重置成 secure_path，
# 所以 command -v 找不到时去 nvm 目录里找：$NVM_DIR、sudo 之前那个用户的 ~/.nvm、
# 当前用户的 ~/.nvm，取已安装的最高版本加进 PATH
find_node() {
  command -v npm >/dev/null 2>&1 && return 0
  local dirs=() d home bin
  [ -n "${NVM_DIR:-}" ] && dirs+=("$NVM_DIR")
  if [ -n "${SUDO_USER:-}" ] && home="$(getent passwd "$SUDO_USER" | cut -d: -f6)" && [ -n "$home" ]; then
    dirs+=("$home/.nvm")
  fi
  dirs+=("$HOME/.nvm" /usr/local/nvm /opt/nvm)
  for d in "${dirs[@]}"; do
    bin="$(ls -d "$d"/versions/node/v*/bin 2>/dev/null | sort -V | tail -n 1 || true)"
    if [ -n "$bin" ] && [ -x "$bin/npm" ] && [ -x "$bin/node" ]; then
      export PATH="$bin:$PATH"
      info "使用 nvm 安装的 Node.js：$bin"
      return 0
    fi
  done
  return 1
}

# Vite 要求 Node.js ^20.19.0 || >=22.12.0
node_version_ok() {
  local v major minor
  v="$(node -v 2>/dev/null)" || return 1
  v="${v#v}"; major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  [ "$major" -eq 20 ] && [ "$minor" -ge 19 ] && return 0
  [ "$major" -eq 22 ] && [ "$minor" -ge 12 ] && return 0
  [ "$major" -ge 23 ]
}

build_web() {
  if ! find_node; then
    warn "未找到 npm（PATH 与 ~/.nvm 中都没有），跳过网页构建（需要 Node.js 20.19+ 或 22.12+）"
    return 0
  fi
  if ! node_version_ok; then
    warn "Node.js $(node -v 2>/dev/null || echo '?')（$(command -v node)）版本过低，跳过网页构建（需要 20.19+ 或 22.12+）"
    return 0
  fi
  info "构建网页 → web/dist（Node.js $(node -v)）"
  (cd "$REPO_DIR/web" && npm ci --no-audit --no-fund && npm run build)
}

cmd_build() {
  case "${1:-all}" in
    all) build_backend; build_web ;;
    backend) build_backend ;;
    web) build_web ;;
    *) die "build 只接受 all|backend|web" ;;
  esac
}

cmd_install() {
  root install
  need systemctl "需要 systemd"
  build_backend
  build_web

  info "安装到 $APP_DIR"
  install -d -m 755 "$APP_DIR/backend" "$APP_DIR/web"
  install -d -m 700 "$APP_DIR/backend/state"
  # 编译产物 server.build 与临时文件 server.new 名字不同（仓库可能就克隆在 APP_DIR 里）；
  # 先写临时文件再 mv：替换正在运行的二进制也是原子的
  install -m 755 "$REPO_DIR/backend/server.build" "$BIN.new"
  rm -f "$REPO_DIR/backend/server.build"
  mv -f "$BIN.new" "$BIN"
  if [ -d "$REPO_DIR/web/dist" ] && [ "$REPO_DIR" != "$APP_DIR" ]; then
    rm -rf "$APP_DIR/web/dist.new"
    cp -r "$REPO_DIR/web/dist" "$APP_DIR/web/dist.new"
    rm -rf "$APP_DIR/web/dist"
    mv "$APP_DIR/web/dist.new" "$APP_DIR/web/dist"
  fi

  info "安装 systemd 服务 $UNIT_DST"
  sed "s#/www/wwwroot/webtrc#$APP_DIR#g" "$UNIT_SRC" > "$UNIT_DST"
  chmod 644 "$UNIT_DST"
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null

  check_geoip
  if systemctl is-active --quiet "$SERVICE"; then
    info "服务正在运行，重启以加载新版本"
    systemctl restart "$SERVICE"
    sleep 2
    systemctl --no-pager --lines=5 status "$SERVICE" || true
  else
    info "安装完成。启动：./deploy.sh start"
  fi
  echo "nginx 配置模板：$REPO_DIR/backend/deploy/nginx.conf；增加节点：$REPO_DIR/backend/deploy/p2p-domain.md"
}

check_geoip() {
  local db
  db="$(grep -o -- '-geoip-db [^ ]*' "$UNIT_DST" 2>/dev/null | awk '{print $2}' || true)"
  if [ -n "$db" ] && [ ! -f "$db" ]; then
    warn "GeoIP 数据库 $db 不存在，节点会启动失败。请放置 MMDB 文件，或从服务文件中删除 -geoip-db 参数。"
  fi
}

cmd_service() {
  root "$1"
  need systemctl "需要 systemd"
  [ -f "$UNIT_DST" ] || die "服务未安装，先执行 ./deploy.sh install"
  systemctl "$1" "$SERVICE"
  sleep 1
  systemctl --no-pager --lines=5 status "$SERVICE" || true
}

cmd_status() {
  systemctl --no-pager --lines=20 status "$SERVICE" || true
  echo
  info "监听端口（8003 API / 4002 浏览器 libp2p / 4001 节点互联，仅多节点时）"
  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>/dev/null | grep -E ':(8003|4001|4002)\b' || warn "未发现监听端口"
  fi
}

cmd_logs() {
  journalctl -u "$SERVICE" -n "${1:-100}" -f --no-pager
}

cmd_check() {
  need curl "用于访问本机 API"
  local ok=0
  if systemctl is-active --quiet "$SERVICE"; then info "服务运行中"; else warn "服务未运行"; ok=1; fi
  if body="$(curl -fsS --max-time 5 "http://$HTTP_ADDR/api/bootstrap")"; then
    info "/api/bootstrap："
    echo "$body"
    echo "$body" | grep -q '/tcp/443/wss' || warn "公布地址中没有浏览器用的 wss 地址，请检查 NODE_ANNOUNCE"
    if echo "$body" | grep -q '/tcp/4001'; then
      info "多节点模式：公布了 4001，确认安全组/宝塔防火墙已放行 4001 tcp/udp"
      command -v dig >/dev/null 2>&1 && info "p2p.webtrc.eu.cc 解析：$(dig +short p2p.webtrc.eu.cc | tr '\n' ' ')"
    else
      info "单节点模式：未公布 4001，无需开放端口"
    fi
  else
    warn "无法访问 http://$HTTP_ADDR/api/bootstrap"; ok=1
  fi
  curl -fsS --max-time 5 "http://$HTTP_ADDR/api/ice" >/dev/null && info "/api/ice 正常" || { warn "/api/ice 异常"; ok=1; }
  check_geoip
  if [ -f /www/server/panel/vhost/nginx/extension/music.webtrc.eu.cc/cloudflare_realip.conf ]; then
    info "nginx 已为 music.webtrc.eu.cc 配置 Cloudflare 真实 IP"
  else
    warn "nginx 未配置 Cloudflare 真实 IP，开橙云后地区会显示成 CF 机房：sudo ./extension/cloudflare-realip.sh install"
  fi
  return $ok
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  install) cmd_install ;;
  start|stop|restart) cmd_service "$1" ;;
  status) cmd_status ;;
  logs) shift; cmd_logs "$@" ;;
  check) cmd_check ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
