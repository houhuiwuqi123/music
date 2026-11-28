#!/usr/bin/env bash
# AURU 节点（Go）+ Candy 广场网页（Vue）：本地开发环境。Windows（Git Bash）、macOS、Linux 通用。
#
#   ./local.sh start | stop | restart    启动 / 停止 / 重启：Go 节点（先在本地编译）+ Vite 开发服务器
#   ./local.sh status                    运行状态 + 监听端口
#
# 运行文件都在 .local/：bin/（编译产物）、state/（节点身份）、logs/、*.pid。
# 环境变量：API_PORT（默认 8003）  LIBP2P_PORT（默认 4002）  WEB_PORT（默认 5173）
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$REPO_DIR/.local"
API_PORT="${API_PORT:-8003}"
LIBP2P_PORT="${LIBP2P_PORT:-4002}"
WEB_PORT="${WEB_PORT:-5173}"
GEOIP_DB="$REPO_DIR/backend/GeoLite2-City2.mmdb"

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=1; EXE=.exe ;; *) WINDOWS=; EXE= ;; esac
NODE_BIN="$RUN_DIR/bin/webtrc-dev$EXE"

if [ -t 1 ]; then C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_B=$'\033[1m'; C_OFF=$'\033[0m'
else C_OK=; C_BAD=; C_B=; C_OFF=; fi
LINE='----------------------------------------------------------------------------------------'

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1 —— $2"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# ---- 进程（Windows 上记录的是原生 PID，用 tasklist / taskkill 管理） ----
alive() { # pid
  [ -n "${1:-}" ] || return 1
  if [ -n "$WINDOWS" ]; then tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -qw "$1"
  else kill -0 "$1" 2>/dev/null; fi
}

mem_kb() { # pid → 常驻内存 KB
  if [ -n "$WINDOWS" ]; then
    tasklist //FI "PID eq $1" //FO CSV //NH 2>/dev/null | awk -F'","' '{gsub(/[^0-9]/, "", $5); print $5}'
  else
    ps -o rss= -p "$1" 2>/dev/null | tr -d ' '
  fi
}

image_of() { # pid → 可执行文件名
  if [ -n "$WINDOWS" ]; then tasklist //FI "PID eq $1" //FO CSV //NH 2>/dev/null | awk -F'","' '{gsub(/"/, "", $1); print $1}'
  else ps -o comm= -p "$1" 2>/dev/null | awk -F/ '{print $NF}'; fi
}

kill_tree() { # pid
  if [ -n "$WINDOWS" ]; then
    taskkill //PID "$1" //T //F >/dev/null 2>&1 || true
  else
    pkill -TERM -P "$1" 2>/dev/null || true
    kill -TERM "$1" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$1" || return 0; sleep 0.5; done
    kill -KILL "$1" 2>/dev/null || true
  fi
}

port_pid() { # 端口 → 监听它的 PID
  if [ -n "$WINDOWS" ]; then
    netstat -ano -p tcp 2>/dev/null | awk -v p=":$1" '$4 == "LISTENING" && substr($2, length($2) - length(p) + 1) == p {print $5; exit}'
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -n 1
  else
    ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2
  fi
}
listening() { [ -n "$(port_pid "$1")" ]; }

native() { if [ -n "$WINDOWS" ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; } # Windows 程序认得的路径

pid_of() { [ -f "$RUN_DIR/$1.pid" ] && tr -d '\r\n ' <"$RUN_DIR/$1.pid" || true; }

# 后台启动；记录 PID（Windows 上换成原生 PID，taskkill 才能结束整棵进程树）
spawn() { # 名称 目录 命令...
  local name="$1" dir="$2" pid; shift 2
  mkdir -p "$RUN_DIR/logs"
  printf '\n===== %s 启动于 %s =====\n' "$name" "$(date '+%F %T')" >>"$RUN_DIR/logs/$name.log"
  (cd "$dir" && exec nohup "$@" >>"$RUN_DIR/logs/$name.log" 2>&1 </dev/null) &
  pid=$!
  if [ -n "$WINDOWS" ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -r "/proc/$pid/winpid" ] && break; sleep 0.2; done
    pid="$(cat "/proc/$pid/winpid" 2>/dev/null || echo "$pid")"
  fi
  echo "$pid" >"$RUN_DIR/$name.pid"
}

wait_port() { # 名称 端口 秒数
  local name="$1" port="$2" i
  for (( i = 0; i < $3 * 2; i++ )); do
    listening "$port" && return 0
    alive "$(pid_of "$name")" || break
    sleep 0.5
  done
  warn "$name 没有在 $port 端口启动，最近的日志（$RUN_DIR/logs/$name.log）："
  tail -n 15 "$RUN_DIR/logs/$name.log" >&2 || true
  return 1
}

# ---- 启动 / 停止 ----
start_node() {
  if alive "$(pid_of node)"; then info "节点已在运行（PID $(pid_of node)）"; return 0; fi
  listening "$API_PORT" && die "端口 $API_PORT 已被 PID $(port_pid "$API_PORT")（$(image_of "$(port_pid "$API_PORT")")）占用"
  need go "请安装 Go 1.27.2+"
  info "本地编译节点 → .local/bin/webtrc-dev$EXE"
  mkdir -p "$RUN_DIR/bin" "$RUN_DIR/state"
  (cd "$REPO_DIR/backend" && CGO_ENABLED=0 go build -o "$NODE_BIN" .)
  local args=(-http "127.0.0.1:$API_PORT" -key "$(native "$RUN_DIR/state/node.key")" -listen "/ip4/127.0.0.1/tcp/$LIBP2P_PORT/ws")
  if [ -f "$GEOIP_DB" ]; then args+=(-geoip-db "$(native "$GEOIP_DB")"); else warn "没有 $GEOIP_DB，地区显示为“地区未知”"; fi
  local xdb xdbs=()
  for xdb in "$REPO_DIR/backend/ip2region_v4.xdb" "$REPO_DIR/backend/ip2region_v6.xdb"; do
    [ -f "$xdb" ] && xdbs+=("$(native "$xdb")")
  done
  if [ ${#xdbs[@]} -gt 0 ]; then args+=(-ip2region "$(IFS=,; echo "${xdbs[*]}")")
  else warn "没有 ip2region 数据库，国内城市精度较低（scripts/update-geoip.sh ip2region 下载）"; fi
  info "启动节点：API 127.0.0.1:$API_PORT，浏览器 libp2p ws://127.0.0.1:$LIBP2P_PORT"
  # Git Bash 会把以 / 开头的参数（multiaddr）当成路径改写成 C:/Program Files/Git/...，关掉这个转换
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' spawn node "$REPO_DIR/backend" "$NODE_BIN" "${args[@]}"
  wait_port node "$API_PORT" 15
}

start_web() {
  if alive "$(pid_of web)"; then info "网页开发服务器已在运行（PID $(pid_of web)）"; return 0; fi
  listening "$WEB_PORT" && die "端口 $WEB_PORT 已被 PID $(port_pid "$WEB_PORT")（$(image_of "$(port_pid "$WEB_PORT")")）占用"
  need node "请安装 Node.js 20.19+ 或 22.12+"
  if [ ! -d "$REPO_DIR/web/node_modules" ]; then
    info "安装网页依赖（npm ci）"
    (cd "$REPO_DIR/web" && npm ci --no-audit --no-fund)
  fi
  info "启动 Vite：http://127.0.0.1:$WEB_PORT（/api 代理到 127.0.0.1:$API_PORT）"
  NODE_HTTP="http://127.0.0.1:$API_PORT" spawn web "$REPO_DIR/web" \
    node node_modules/vite/bin/vite.js --host 127.0.0.1 --port "$WEB_PORT" --strictPort
  wait_port web "$WEB_PORT" 30
}

stop_one() { # 名称 端口 可执行文件名（端口上的进程是它才结束，防止误杀别的程序）
  local name="$1" port="$2" image="$3" pid
  pid="$(pid_of "$name")"
  if alive "$pid"; then
    info "停止 $name（PID $pid）"
    kill_tree "$pid"
  fi
  rm -f "$RUN_DIR/$name.pid"
  # PID 文件丢了或进程换过：按端口找回自己的进程
  pid="$(port_pid "$port")"
  if [ -n "$pid" ]; then
    if [ "$(image_of "$pid")" = "$image" ]; then
      info "停止占用 $port 端口的 $image（PID $pid）"
      kill_tree "$pid"
    else
      warn "端口 $port 仍被 PID $pid（$(image_of "$pid")）占用，不是本脚本启动的，未处理"
    fi
  fi
}

cmd_start() { mkdir -p "$RUN_DIR"; start_node; start_web; cmd_status; }
cmd_stop() { stop_one web "$WEB_PORT" "node$EXE"; stop_one node "$API_PORT" "webtrc-dev$EXE"; cmd_status; }

# ---- status ----
pad() { # 按显示宽度补空格（中文占 2 列）
  local LC_ALL=C s="$1" w="$2" ascii width
  ascii="${s//[^[:print:]]/}"
  width=$(( ${#ascii} + (${#s} - ${#ascii}) * 2 / 3 ))
  printf '%s%*s' "$s" $(( w > width ? w - width : 0 )) ''
}

fmt_mem() { if [ -n "${1:-}" ] && [ "$1" -gt 0 ] 2>/dev/null; then printf '%d MB' $(( ($1 + 512) / 1024 )); else printf -- '-'; fi; }
file_time() { if [ -e "$1" ]; then date -r "$1" '+%F %T' 2>/dev/null || date -d "@$(stat -c %Y "$1")" '+%F %T'; else printf '不存在'; fi; }

row() { # 名称 标签
  local name="$1" label="$2" pid
  pid="$(pid_of "$name")"
  if alive "$pid"; then
    printf '  %s %s%s%s  PID %s  内存 %s  启动于 %s\n' "$(pad "$label" 24)" "$C_OK" "$(pad 运行中 6)" "$C_OFF" \
      "$(pad "$pid" 8)" "$(pad "$(fmt_mem "$(mem_kb "$pid")")" 8)" "$(file_time "$RUN_DIR/$name.pid")"
  else
    printf '  %s %s%s%s  PID %s  内存 %s\n' "$(pad "$label" 24)" "$C_BAD" "$(pad 已停止 6)" "$C_OFF" "$(pad - 8)" "$(pad - 8)"
  fi
}

port_mark() { if listening "$1"; then printf '%s%s ✓%s %s' "$C_OK" "$1" "$C_OFF" "$2"; else printf '%s%s ✗%s %s' "$C_BAD" "$1" "$C_OFF" "$2"; fi; }

cmd_status() {
  echo
  printf '%sAURU 节点 · 本地开发%s   API 端口 %s   网页 http://127.0.0.1:%s\n' "$C_B" "$C_OFF" "$API_PORT" "$WEB_PORT"
  printf '        目录 %s   运行文件 .local/   节点构建于 %s\n' "$(native "$REPO_DIR")" "$(file_time "$NODE_BIN")"
  echo "$LINE"
  row node "webtrc 节点（Go）"
  row web "网页（Vite 开发服务器）"
  echo "$LINE"
  printf '        端口：%s   %s   %s\n' "$(port_mark "$API_PORT" "API + iOS 网关")" "$(port_mark "$LIBP2P_PORT" "浏览器 libp2p")" "$(port_mark "$WEB_PORT" Vite)"
  printf '        日志：.local/logs/node.log  .local/logs/web.log\n'
  echo
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) stop_one web "$WEB_PORT" "node$EXE"; stop_one node "$API_PORT" "webtrc-dev$EXE"; cmd_start ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
