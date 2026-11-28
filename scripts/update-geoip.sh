#!/usr/bin/env bash
# 下载最新的 IP 地区数据库到 backend/（或 GEOIP_DIR）：
#
#   scripts/update-geoip.sh [all|geolite|ip2region]   默认 all
#
#   geolite    MaxMind GeoLite2-City → GeoLite2-City2.mmdb（全球，带坐标）
#              需要免费账号：https://www.maxmind.com/en/geolite2/signup
#              环境变量 MAXMIND_ACCOUNT_ID、MAXMIND_LICENSE_KEY；没设置时从 /etc/webtrc.env 读取
#   ip2region  lionsoul2014/ip2region → ip2region_v4.xdb、ip2region_v6.xdb（国内省份/城市更准）
#              IP2REGION_BASE 可换成镜像地址（默认 GitHub raw）
#
# 文件先下载到临时文件、校验后再替换，失败不会破坏正在使用的数据库。节点启动时加载数据库，
# 更新后需重启：sudo ./deploy.sh install（会把新文件复制到安装目录并重启）。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${GEOIP_DIR:-$REPO_DIR/backend}"
ENV_FILE="${ENV_FILE:-/etc/webtrc.env}"
IP2REGION_BASE="${IP2REGION_BASE:-https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data}"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null || die "缺少 curl"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 原子替换：同目录下 mv
replace() { # <新文件> <目标>
  install -m 644 "$1" "$2.new"
  mv -f "$2.new" "$2"
  info "已更新 $2（$(du -h "$2" | cut -f1)）"
}

geolite() {
  if [ -z "${MAXMIND_LICENSE_KEY:-}" ] && [ -r "$ENV_FILE" ]; then
    MAXMIND_ACCOUNT_ID="$(sed -n 's/^MAXMIND_ACCOUNT_ID=//p' "$ENV_FILE" | tail -n 1)"
    MAXMIND_LICENSE_KEY="$(sed -n 's/^MAXMIND_LICENSE_KEY=//p' "$ENV_FILE" | tail -n 1)"
  fi
  [ -n "${MAXMIND_ACCOUNT_ID:-}" ] && [ -n "${MAXMIND_LICENSE_KEY:-}" ] ||
    die "GeoLite2 需要 MAXMIND_ACCOUNT_ID 和 MAXMIND_LICENSE_KEY（环境变量或 $ENV_FILE）"
  command -v tar >/dev/null || die "缺少 tar"
  local url="https://download.maxmind.com/geoip/databases/GeoLite2-City/download?suffix=tar.gz"
  info "下载 GeoLite2-City …"
  curl -fsSL --retry 3 -u "$MAXMIND_ACCOUNT_ID:$MAXMIND_LICENSE_KEY" -o "$TMP/city.tar.gz" "$url" ||
    die "GeoLite2 下载失败（账号 ID / License Key 是否正确？）"
  curl -fsSL --retry 3 -u "$MAXMIND_ACCOUNT_ID:$MAXMIND_LICENSE_KEY" -o "$TMP/city.sha256" "$url.sha256" ||
    die "GeoLite2 校验文件下载失败"
  local want got
  want="$(awk '{print $1; exit}' "$TMP/city.sha256")"
  got="$( (sha256sum "$TMP/city.tar.gz" 2>/dev/null || shasum -a 256 "$TMP/city.tar.gz") | awk '{print $1}')"
  [ "$want" = "$got" ] || die "GeoLite2 SHA-256 不符（$got ≠ $want）"
  tar -xzf "$TMP/city.tar.gz" -C "$TMP"
  local mmdb
  mmdb="$(find "$TMP" -name 'GeoLite2-City.mmdb' | head -n 1)"
  [ -n "$mmdb" ] && [ -s "$mmdb" ] || die "压缩包里没有 GeoLite2-City.mmdb"
  replace "$mmdb" "$DIR/GeoLite2-City2.mmdb"
}

ip2region() {
  local name
  for name in ip2region_v4.xdb ip2region_v6.xdb; do
    info "下载 $name …"
    curl -fsSL --retry 3 -o "$TMP/$name" "$IP2REGION_BASE/$name" || die "$name 下载失败（可设置 IP2REGION_BASE 换镜像）"
    # xdb 文件头 256 字节 + 512 KB 向量索引；过小说明下到的是错误页
    [ "$(wc -c <"$TMP/$name")" -gt 1048576 ] || die "$name 文件异常（太小）"
    replace "$TMP/$name" "$DIR/$name"
  done
}

mkdir -p "$DIR"
case "${1:-all}" in
  all) geolite; ip2region ;;
  geolite) geolite ;;
  ip2region) ip2region ;;
  *) die "用法：$0 [all|geolite|ip2region]" ;;
esac
