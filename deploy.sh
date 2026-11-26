#!/usr/bin/env bash
# AURU 节点（Go）+ Candy 广场网页（Vue）：生产环境编译、安装、服务管理。
#
#   ./deploy.sh build [all|backend|web]   编译（默认 all）
#   ./deploy.sh install                   编译并安装：二进制、网页、systemd 服务；若服务在运行则重启
#   ./deploy.sh start | stop | restart    控制 systemd 服务
#   ./deploy.sh status                    服务状态 + 监听端口
#   ./deploy.sh logs [行数]               跟踪日志（默认最近 100 行）
#   ./deploy.sh check                     自检：本机 API、bootstrap 列表、端口、GeoIP 文件
#
# Go 二进制在本地编译：开发机上执行 ./deploy.sh build backend，得到 backend/bin/webtrc-linux-amd64
# 和源码指纹 .src，提交（或上传）到服务器。install 发现二进制与源码一致就直接安装；不一致或没有时
# 才在服务器上编译，并以最低 CPU/IO 优先级、限制并发和内存运行，不挤占线上服务。
#
# 环境变量：APP_DIR（安装目录，默认 /www/wwwroot/webtrc）  SERVICE（默认 webtrc）
#          TARGET_ARCH（build backend 的目标架构，默认 amd64；在 Linux 上默认本机架构）
#          BUILD_JOBS（服务器上编译的并发数，默认 CPU 核数的一半、最多 2）
#          NODE_MEM_MB（构建网页时 Node.js 的堆上限，默认 1024）  FORCE=1（网页源码没变也重新构建）
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-/www/wwwroot/webtrc}"
SERVICE="${SERVICE:-webtrc}"
UNIT_SRC="$REPO_DIR/backend/webtrc.service"
UNIT_DST="/etc/systemd/system/${SERVICE}.service"
ENV_FILE="/etc/webtrc.env"
BIN="$APP_DIR/backend/server"
PREBUILT_DIR="$REPO_DIR/backend/bin"
WEB_STAMP="$REPO_DIR/web/.dist-src"

if [ -t 1 ]; then C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_OFF=$'\033[0m'
else C_OK=; C_BAD=; C_WARN=; C_DIM=; C_B=; C_OFF=; fi
LINE='----------------------------------------------------------------------------------------'

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1 —— $2"; }
root() { [ "$(id -u)" -eq 0 ] || die "此操作需要 root（sudo ./deploy.sh $*）"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# ---- 从服务文件读取端口（已安装的优先），改了 webtrc.service 这里自动跟着变 ----
unit_file() { if [ -f "$UNIT_DST" ]; then echo "$UNIT_DST"; else echo "$UNIT_SRC"; fi; }
unit_arg() { grep -o -- "-$1 [^ ]*" "$(unit_file)" 2>/dev/null | head -n 1 | awk '{print $2}' || true; }
HTTP_ADDR="$(unit_arg http)"; HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8003}"
API_PORT="${HTTP_ADDR##*:}"
LIBP2P_PORT="$(unit_arg listen | grep -o 'tcp/[0-9]*/ws' | head -n 1 | tr -dc '0-9' || true)"
LIBP2P_PORT="${LIBP2P_PORT:-4002}"

# ---- 平台与资源 ----
is_linux() { [ "$(uname -s)" = Linux ]; }
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; armv7*|armv6*) echo arm ;; *) uname -m ;;
  esac
}
target_arch() { if [ -n "${TARGET_ARCH:-}" ]; then echo "$TARGET_ARCH"; elif is_linux; then host_arch; else echo amd64; fi; }

build_jobs() {
  local n
  n="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  n=$(( n / 2 )); [ "$n" -lt 1 ] && n=1; [ "$n" -gt 2 ] && n=2
  echo "${BUILD_JOBS:-$n}"
}

warn_low_mem() { # 建议的 MB 数
  local avail
  avail="$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || true)"
  if [ -n "$avail" ] && [ "$avail" -lt "$1" ]; then
    warn "可用内存只有 ${avail} MB（建议 ≥ $1 MB），编译会很慢甚至被 OOM 终止；建议在本地编译后提交"
  fi
}

# Linux 上以最低 CPU 优先级和最低的 best-effort IO 优先级运行；其他平台原样运行
gentle() {
  local cmd=("$@")
  if is_linux; then
    command -v ionice >/dev/null 2>&1 && cmd=(ionice -c2 -n7 "${cmd[@]}")
    command -v nice >/dev/null 2>&1 && cmd=(nice -n 19 "${cmd[@]}")
  fi
  "${cmd[@]}"
}

# ---- 源码指纹：路径 + 内容（去掉 CR，Windows 检出的 CRLF 与 Linux 上的 LF 算出一样的值） ----
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-64; }
tree_hash() { # 目录 find参数...
  local dir="$1"; shift
  (
    cd "$dir"
    { find "$@" 2>/dev/null || true; } | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"; tr -d '\r' <"$f"
    done
  ) | sha256
}
backend_hash() {
  tree_hash "$REPO_DIR/backend" . \( -path ./bin -o -path ./state -o -path ./deploy \) -prune -o -type f \
    \( \( -name '*.go' ! -name '*_test.go' \) -o -name go.mod -o -name go.sum \) -print
}
web_hash() {
  tree_hash "$REPO_DIR/web" index.html package.json package-lock.json vite.config.ts tsconfig.json src public -type f
}
read_stamp() { [ -f "$1" ] && tr -d '\r\n' <"$1" || true; }

# ---- 编译 ----
build_backend() {
  need go "请安装 Go（go.mod 要求 1.27.2+；GOTOOLCHAIN=auto 时会自动下载对应版本）"
  local arch out hash jobs
  arch="$(target_arch)"
  out="$PREBUILT_DIR/webtrc-linux-$arch"
  hash="$(backend_hash)"
  mkdir -p "$PREBUILT_DIR"
  if is_linux; then
    jobs="$(build_jobs)"
    warn_low_mem 700
    info "编译节点（linux/$arch，低优先级，并发 $jobs）→ backend/bin/${out##*/}"
    (cd "$REPO_DIR/backend" && GOOS=linux GOARCH="$arch" CGO_ENABLED=0 GOMAXPROCS="$jobs" GOGC=50 GOMEMLIMIT=600MiB \
      gentle go build -p "$jobs" -trimpath -ldflags "-s -w" -o "$out.tmp" .)
  else
    info "交叉编译节点（linux/$arch）→ backend/bin/${out##*/}"
    (cd "$REPO_DIR/backend" && GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$out.tmp" .)
  fi
  mv -f "$out.tmp" "$out"
  printf '%s\n' "$hash" >"$out.src"
  info "完成：$(du -h "$out" | cut -f1)，源码指纹 ${hash:0:12}"
  is_linux || info "把 backend/bin/${out##*/} 和 ${out##*/}.src 提交（或上传）到服务器，再执行 sudo ./deploy.sh install"
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
  local web="$REPO_DIR/web" hash lock
  hash="$(web_hash)"
  if [ -z "${FORCE:-}" ] && [ -f "$web/dist/index.html" ] && [ "$(read_stamp "$WEB_STAMP")" = "$hash" ]; then
    info "网页源码没有变化，沿用 web/dist（FORCE=1 可强制重新构建）"
    return 0
  fi
  if ! find_node; then
    warn "未找到 npm（PATH 与 ~/.nvm 中都没有），跳过网页构建（需要 Node.js 20.19+ 或 22.12+）"
    return 0
  fi
  if ! node_version_ok; then
    warn "Node.js $(node -v 2>/dev/null || echo '?')（$(command -v node)）版本过低，跳过网页构建（需要 20.19+ 或 22.12+）"
    return 0
  fi
  is_linux && warn_low_mem 1200
  # 依赖只在 package-lock.json 变了之后才重新安装
  lock="$(tr -d '\r' <"$web/package-lock.json" | sha256)"
  if [ ! -d "$web/node_modules" ] || [ "$(read_stamp "$web/node_modules/.deploy-lock")" != "$lock" ]; then
    info "安装网页依赖（npm ci）"
    (cd "$web" && gentle npm ci --no-audit --no-fund)
    printf '%s\n' "$lock" >"$web/node_modules/.deploy-lock"
  fi
  info "构建网页 → web/dist（Node.js $(node -v)，堆上限 ${NODE_MEM_MB:-1024} MB）"
  (cd "$web" && NODE_OPTIONS="--max-old-space-size=${NODE_MEM_MB:-1024}" gentle npm run build)
  printf '%s\n' "$hash" >"$WEB_STAMP"
}

cmd_build() {
  case "${1:-all}" in
    all) build_backend; build_web ;;
    backend) build_backend ;;
    web) build_web ;;
    frontadmin) die "本项目没有 frontadmin，网页在 web/：./deploy.sh build web" ;;
    *) die "build 只接受 all|backend|web" ;;
  esac
}

# ---- 安装 ----
# 输出要安装的节点二进制路径：优先用本地编译、与源码指纹一致的那份，否则在服务器上编译
backend_binary() {
  local arch out
  arch="$(host_arch)"
  out="$PREBUILT_DIR/webtrc-linux-$arch"
  if [ -f "$out" ] && [ -f "$out.src" ]; then
    if [ "$(read_stamp "$out.src")" = "$(backend_hash)" ]; then
      info "使用本地预编译的节点：backend/bin/${out##*/}（$(du -h "$out" | cut -f1)）" >&2
      echo "$out"; return
    fi
    warn "backend/bin/${out##*/} 与当前 Go 源码不一致（改了源码但没在本地重新编译），改为在服务器上编译"
  else
    warn "没有本地预编译的 backend/bin/${out##*/}，在服务器上编译（建议在开发机执行 ./deploy.sh build backend 后提交）"
  fi
  TARGET_ARCH="$arch" build_backend >&2
  echo "$out"
}

install_geoip() { # 服务文件引用的 MMDB 不在安装目录时，从仓库复制
  local db name
  db="$(unit_arg geoip-db)"
  [ -n "$db" ] && [ ! -f "$db" ] || return 0
  name="${db##*/}"
  if [ -f "$REPO_DIR/backend/$name" ]; then
    install -m 644 "$REPO_DIR/backend/$name" "$db"
    info "已复制 GeoIP 数据库 → $db"
  fi
}

check_geoip() {
  local db
  db="$(unit_arg geoip-db)"
  if [ -z "$db" ]; then
    warn "服务文件没有 -geoip-db，访客地区会显示为“地区未知”"
  elif [ -f "$db" ]; then
    info "GeoIP 数据库：$db（$(du -h "$db" | cut -f1)）"
  else
    warn "GeoIP 数据库 $db 不存在，节点会启动失败。请放置 MMDB 文件，或从服务文件中删除 -geoip-db 参数。"
    return 1
  fi
}

cmd_install() {
  root install
  need systemctl "需要 systemd"
  local src
  src="$(backend_binary)"
  build_web

  info "安装到 $APP_DIR"
  install -d -m 755 "$APP_DIR/backend" "$APP_DIR/web"
  install -d -m 700 "$APP_DIR/backend/state"
  # 先写临时文件再 mv：替换正在运行的二进制也是原子的（仓库可能就克隆在 APP_DIR 里）
  install -m 755 "$src" "$BIN.new"
  mv -f "$BIN.new" "$BIN"
  if [ -f "$REPO_DIR/web/dist/index.html" ]; then
    if [ "$REPO_DIR" != "$APP_DIR" ]; then
      rm -rf "$APP_DIR/web/dist.new"
      cp -r "$REPO_DIR/web/dist" "$APP_DIR/web/dist.new"
      rm -rf "$APP_DIR/web/dist"
      mv "$APP_DIR/web/dist.new" "$APP_DIR/web/dist"
    fi
  else
    warn "web/dist 不存在，网页未更新"
  fi

  info "安装 systemd 服务 $UNIT_DST"
  sed "s#/www/wwwroot/webtrc#$APP_DIR#g" "$UNIT_SRC" >"$UNIT_DST"
  chmod 644 "$UNIT_DST"
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  install_geoip
  check_geoip || true

  if systemctl is-active --quiet "$SERVICE"; then
    info "服务正在运行，重启以加载新版本"
    systemctl restart "$SERVICE"
    sleep 2
  else
    info "安装完成。启动：sudo ./deploy.sh start"
  fi
  cmd_status
  echo "        nginx 配置：$REPO_DIR/DEPLOY.md（模板 backend/deploy/nginx.conf）"
  echo
}

cmd_service() {
  root "$1"
  need systemctl "需要 systemd"
  [ -f "$UNIT_DST" ] || die "服务未安装，先执行 sudo ./deploy.sh install"
  systemctl "$1" "$SERVICE" || { journalctl -u "$SERVICE" -n 20 --no-pager || true; exit 1; }
  [ "$1" = stop ] || sleep 2
  cmd_status
}

# ---- status ----
# 按显示宽度补空格（中文占 2 列）。LC_ALL=C 下按字节算：中文 UTF-8 每字 3 字节、2 列
pad() {
  local LC_ALL=C s="$1" w="$2" ascii width
  ascii="${s//[^[:print:]]/}"
  width=$(( ${#ascii} + (${#s} - ${#ascii}) * 2 / 3 ))
  printf '%s%*s' "$s" $(( w > width ? w - width : 0 )) ''
}

fmt_mem() { # KB → "14 MB"
  if [ -n "${1:-}" ] && [ "$1" -gt 0 ] 2>/dev/null; then printf '%d MB' $(( ($1 + 512) / 1024 )); else printf -- '-'; fi
}

proc_start() { # PID → "2026-11-08 22:13:07"
  local s; s="$(ps -o lstart= -p "$1" 2>/dev/null)" || return 0
  date -d "$s" '+%F %T' 2>/dev/null || printf '%s' "$s"
}

file_time() { if [ -e "$1" ]; then date -d "@$(stat -c %Y "$1")" '+%F %T'; else printf '不存在'; fi; }

# 一行：名称 状态 PID 内存 启动时间。state 取 运行中/启动中/已停止/失败/未安装
print_row() { # label state pid mem_kb since
  local label="$1" state="$2" pid="${3:--}" mem since="${5:-}" color word
  mem="$(fmt_mem "${4:-}")"
  case "$state" in
    运行中) color=$C_OK; word=启动于 ;;
    启动中) color=$C_WARN; word=启动于 ;;
    未安装) color=$C_DIM; word=; since= ;;
    *) color=$C_BAD; word=停止于 ;;
  esac
  [ "$state" = 运行中 ] || [ "$state" = 启动中 ] || { pid=-; mem=-; }
  printf '  %s %s%s%s  PID %s  内存 %s  %s %s\n' \
    "$(pad "$label" 24)" "$color" "$(pad "$state" 6)" "$C_OFF" \
    "$(pad "$pid" 8)" "$(pad "$mem" 8)" "$word" "$since"
}

# systemd 服务的状态；输出 "state pid mem_kb since"（since 含空格，放最后）
unit_info() {
  local unit="$1" k v active= pid=0 mem= enter= exit_ts= state ts
  if ! systemctl cat "$unit" >/dev/null 2>&1; then echo "未安装 - - "; return; fi
  while IFS='=' read -r k v; do
    case "$k" in
      ActiveState) active="$v" ;;
      MainPID) pid="$v" ;;
      MemoryCurrent) mem="$v" ;;
      ActiveEnterTimestamp) enter="$v" ;;
      InactiveEnterTimestamp) exit_ts="$v" ;;
    esac
  done < <(systemctl show "$unit" -p ActiveState -p MainPID -p MemoryCurrent \
             -p ActiveEnterTimestamp -p InactiveEnterTimestamp 2>/dev/null)
  case "$active" in
    active) state=运行中 ;; activating|reloading) state=启动中 ;; failed) state=失败 ;; *) state=已停止 ;;
  esac
  # MemoryCurrent 未开启记账时是 [not set] 或 2^64-1，退回读进程 RSS
  if [[ "$mem" =~ ^[0-9]+$ ]] && [ "${#mem}" -lt 19 ]; then mem=$(( mem / 1024 ))
  elif [ "$pid" -gt 0 ] 2>/dev/null; then mem="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
  else mem=; fi
  ts="$enter"; [ "$state" = 运行中 ] || [ "$state" = 启动中 ] || ts="$exit_ts"
  ts="$(awk '{print $2" "$3}' <<<"$ts")"
  echo "$state ${pid:-0} ${mem:--} ${ts}"
}

# nginx：宝塔用 /etc/init.d 启动，systemd 里常看不到正确状态，按进程判断
nginx_row() {
  local pid mem
  pid="$(pgrep -o -x nginx 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    mem="$(ps -C nginx -o rss= 2>/dev/null | awk '{s += $1} END {print s + 0}')"
    print_row "nginx（依赖）" 运行中 "$pid" "$mem" "$(proc_start "$pid")"
  elif command -v nginx >/dev/null 2>&1 || [ -x /www/server/nginx/sbin/nginx ]; then
    print_row "nginx（依赖）" 已停止
  else
    print_row "nginx（依赖）" 未安装
  fi
}

listening() { # 端口 → 是否有 TCP 监听
  local list
  if command -v ss >/dev/null 2>&1; then list="$(ss -ltnH 2>/dev/null | awk '{print $4}')"
  else list="$(netstat -ltn 2>/dev/null | awk 'NR > 2 {print $4}')"; fi
  grep -qE "[:.]$1\$" <<<"$list"
}

port_mark() { # 端口 说明
  if listening "$1"; then printf '%s%s ✓%s %s' "$C_OK" "$1" "$C_OFF" "$2"
  else printf '%s%s ✗%s %s' "$C_BAD" "$1" "$C_OFF" "$2"; fi
}

cmd_status() {
  local user state pid mem since config="$UNIT_DST"
  user="$(systemctl show "$SERVICE" -p User --value 2>/dev/null || true)"
  [ -f "$ENV_FILE" ] && config="$config + $ENV_FILE"
  echo
  printf '%sAURU 节点 · 服务状态（systemd）%s   API 端口 %s   libp2p 端口 %s\n' "$C_B" "$C_OFF" "$API_PORT" "$LIBP2P_PORT"
  printf '        目录 %s   配置 %s   运行用户 %s   二进制构建于 %s\n' "$APP_DIR" "$config" "${user:-root}" "$(file_time "$BIN")"
  echo "$LINE"
  read -r state pid mem since <<<"$(unit_info "$SERVICE")"
  print_row "$SERVICE" "$state" "$pid" "$mem" "$since"
  nginx_row
  if systemctl cat coturn >/dev/null 2>&1; then # 可选的 TURN：装了才显示
    read -r state pid mem since <<<"$(unit_info coturn)"
    print_row "coturn（可选 TURN）" "$state" "$pid" "$mem" "$since"
  fi
  echo "$LINE"
  printf '        端口：%s   %s   %s' "$(port_mark "$API_PORT" "API + iOS 网关")" "$(port_mark "$LIBP2P_PORT" "浏览器 libp2p")" "$(port_mark 443 nginx)"
  listening 4001 && printf '   %s' "$(port_mark 4001 多节点互联)"
  echo
  printf '        前端：%s（构建于 %s），由 Nginx 托管\n' "$APP_DIR/web/dist" "$(file_time "$APP_DIR/web/dist/index.html")"
  printf '        日志：./deploy.sh logs [行数]（journalctl -u %s），自检：./deploy.sh check\n' "$SERVICE"
  echo
}

cmd_logs() {
  local n="${1:-100}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "行数必须是数字：./deploy.sh logs 200"
  journalctl -u "$SERVICE" -n "$n" -f --no-pager -o short-iso
}

# ---- check ----
cmd_check() {
  need curl "用于访问本机 API"
  local fail=0 body domain addrs
  echo
  if systemctl is-active --quiet "$SERVICE"; then info "服务 $SERVICE 运行中"; else warn "服务 $SERVICE 未运行"; fail=1; fi

  if body="$(curl -fsS --max-time 5 "http://$HTTP_ADDR/api/bootstrap")"; then
    addrs="$(grep -o '"/[^"]*"' <<<"$body" | tr -d '"' || true)"
    info "/api/bootstrap 正常，节点数 $(grep -o '"peerId"' <<<"$body" | wc -l | tr -d ' ')，公布地址："
    sed 's/^/      /' <<<"${addrs:-（无）}"
    grep -q '/tcp/443/wss' <<<"$addrs" || { warn "公布地址里没有浏览器用的 /tcp/443/wss，请检查 NODE_ANNOUNCE"; fail=1; }
    if grep -q '/tcp/4001' <<<"$addrs"; then
      info "多节点模式：公布了 4001，确认安全组 / 宝塔防火墙已放行 4001 tcp/udp"
    else
      info "单节点模式：未公布 4001，无需开放端口"
    fi
  else
    warn "无法访问 http://$HTTP_ADDR/api/bootstrap"; fail=1
  fi
  if curl -fsS --max-time 5 "http://$HTTP_ADDR/api/ice" >/dev/null; then info "/api/ice 正常"; else warn "/api/ice 异常"; fail=1; fi

  for p in "$API_PORT:API + iOS 网关" "$LIBP2P_PORT:浏览器 libp2p" "443:nginx"; do
    if listening "${p%%:*}"; then info "端口 ${p%%:*}（${p#*:}）在监听"; else warn "端口 ${p%%:*}（${p#*:}）没有监听"; fail=1; fi
  done

  check_geoip || fail=1

  domain="$(grep -o 'NODE_ANNOUNCE=/dns4/[^/]*' "$(unit_file)" 2>/dev/null | head -n 1 | sed 's#.*/dns4/##' || true)"
  if [ -n "$domain" ]; then
    if [ -f "/www/server/panel/vhost/nginx/extension/$domain/cloudflare_realip.conf" ]; then
      info "nginx 已为 $domain 配置 Cloudflare 真实 IP"
    else
      warn "nginx 未配置 Cloudflare 真实 IP，开橙云后地区会显示成 CF 机房：sudo ./extension/cloudflare-realip.sh install"
    fi
  fi
  echo
  if [ "$fail" -eq 0 ]; then info "自检通过"; else warn "自检发现问题，见上方警告"; fi
  return "$fail"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  install) cmd_install ;;
  start|stop|restart) cmd_service "$1" ;;
  status) cmd_status ;;
  logs) shift; cmd_logs "$@" ;;
  check) cmd_check ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
