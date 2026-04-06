#!/usr/bin/env bash
set -euo pipefail
# =========================
# suoha x-tunnel FINAL
# - 修复：opera-proxy 强制下载导致的 404 问题（改为按需下载）
# - 修复：使用 GitHub API 动态解析最新真实下载链接，彻底解决作者改名导致的 404
# =========================

CONFIG_FILE="${HOME:-/root}/.suoha_tunnel_config"

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")

say(){ printf "%s\n" "$*"; }

os_index(){
  local n=0
  local pretty
  pretty="$(grep -i PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '"' -f2 | awk '{print $1}' || true)"
  for i in "${linux_os[@]}"; do
    if [[ "$i" == "$pretty" ]]; then
      echo "$n"; return
    fi
    n=$((n+1))
  done
  >&2 echo "当前系统 ${pretty:-Unknown} 没有适配, 默认使用APT"
  echo 0
}

need_cmd(){
  local cmd="$1" idx="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ${linux_update[$idx]} >/dev/null 2>&1 || true
    ${linux_install[$idx]} "$cmd" >/dev/null 2>&1 || true
  fi
}

get_free_port() {
  while true; do
    local PORT=$((RANDOM % 64512 + 1024))
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt | awk '{print $4}' | grep -qE ":${PORT}$"; then echo "$PORT"; return; fi
    elif command -v lsof >/dev/null 2>&1; then
      if ! lsof -i TCP:"$PORT" >/dev/null 2>&1; then echo "$PORT"; return; fi
    else
      echo "$PORT"; return
    fi
  done
}

stop_screen(){
  local name="$1"
  screen -S "$name" -X quit >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    if ! screen -list 2>/dev/null | grep -q "\.${name}[[:space:]]"; then return; fi
    sleep 1
  done
}

# 动态提取 Github 最新发布的直链
extract_github_url() {
  local repo="$1"
  local keyword="$2"
  local json
  json="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)"
  if ! echo "$json" | grep -q '"browser_download_url"'; then
    json="$(curl -fsSL "https://api.github.com/repos/${repo}/releases" 2>/dev/null || true)"
  fi
  echo "$json" | grep -o '"browser_download_url": "[^"]*"' | cut -d'"' -f4 | grep -iE "$keyword" | grep -vE '\.sha256|\.md5|\.txt|\.sig|\.deb|\.rpm|\.msi|\.zip|\.tar\.gz' | head -n 1
}

download_bin(){
  local out="$1"
  local url="$2"
  if [[ -f "$out" ]]; then return 0; fi
  if curl -fsSL "$url" -o "$out"; then
    chmod +x "$out"
    return 0
  fi
  >&2 echo "[ERROR] 下载 $out 失败！链接: $url"
  exit 1
}

detect_ws_port(){
  ss -lntp 2>/dev/null | awk '/x-tunnel-linux/ && /127\.0\.0\.1:/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | head -n1 || true
}

http_head(){ curl -I "https://${1}" 2>/dev/null | sed -n '1,8p' || true; }
tcp_check(){ command -v nc >/dev/null && nc -vz "$1" 443 || true; }
tls_check(){ command -v openssl >/dev/null && echo | openssl s_client -connect "${1}:443" -servername "${1}" 2>/dev/null | sed -n '1,12p' || true; }

self_check(){
  local bind_domain="${1:-}" try_domain="${2:-}" wsport="${3:-}"
  echo; say "=============================="; say "自检 / Debug"; say "=============================="
  say "screen sessions:"; screen -list 2>/dev/null || true; echo
  
  [[ -z "$wsport" ]] && wsport="$(detect_ws_port || true)"
  if [[ -n "$wsport" ]]; then
    say "[OK] 本地监听: 127.0.0.1:${wsport}"
    ss -lntp 2>/dev/null | grep -E "127\.0\.0\.1:${wsport}\b" || true
  else
    say "[FAIL] 未检测到 x-tunnel 本地监听端口"
  fi
  echo
  if [[ -n "$bind_domain" ]]; then
    say "== 绑定域名检测: ${bind_domain} =="
    tcp_check "$bind_domain"; tls_check "$bind_domain"; http_head "$bind_domain"; echo
  fi
  if [[ -n "$try_domain" ]]; then
    say "== 临时域名检测: ${try_domain} =="
    tcp_check "$try_domain"; tls_check "$try_domain"; http_head "$try_domain"; echo
  fi
  cat <<EOF
解释：
- 401 Unauthorized：正常！说明已到达 x-tunnel，但需要 token。
- 200 OK：也可能正常，请用客户端带 token 真正连接测试。
- 502 Bad Gateway：Cloudflare 连不到本地服务。
- 530：被 Cloudflare Access 拦截。
EOF
}

save_config(){
  {
    echo "wsport=${wsport:-}"
    echo "metricsport=${metricsport:-}"
    echo "try_domain=${TRY_DOMAIN:-}"
    echo "bind_enable=${bind_enable:-0}"
    echo "bind_domain=${bind_domain:-}"
    echo "token=${token:-}"
  } > "$CONFIG_FILE"
}

load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"; return 0
  else
    return 1
  fi
}
remove_config(){ rm -f "$CONFIG_FILE"; }

# ------------- core -------------
quicktunnel(){
  local arch
  arch="$(uname -m)"
  
  # 1. x-tunnel
  case "$arch" in
    x86_64|x64|amd64) download_bin "x-tunnel-linux" "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-amd64" ;;
    i386|i686)        download_bin "x-tunnel-linux" "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-386" ;;
    armv8|arm64|aarch64) download_bin "x-tunnel-linux" "https://www.baipiao.eu.org/xtunnel/x-tunnel-linux-arm64" ;;
    *) say "当前架构 ${arch} 没有适配"; exit 1 ;;
  esac

  # 2. cloudflared
  if [[ ! -f "cloudflared-linux" ]]; then
    local cf_kw
    case "$arch" in
      x86_64|x64|amd64) cf_kw="linux-amd64" ;;
      i386|i686)        cf_kw="linux-386" ;;
      armv8|arm64|aarch64) cf_kw="linux-arm64" ;;
    esac
    local cf_url
    cf_url="$(extract_github_url "cloudflare/cloudflared" "cloudflared-$cf_kw")"
    if [[ -n "$cf_url" ]]; then
      download_bin "cloudflared-linux" "$cf_url"
    else
      download_bin "cloudflared-linux" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-$cf_kw"
    fi
  fi

  if [[ -n "${wsport:-}" ]]; then
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${wsport}$"; then
      say "[ERROR] 固定端口 ${wsport} 已被占用，请手动释放"
      exit 1
    fi
  fi

  # 3. opera-proxy (ONLY IF ENABLED)
  if [[ "${opera:-0}" == "1" ]]; then
    if [[ ! -f "opera-linux" ]]; then
      local op_kw
      case "$arch" in
        x86_64|x64|amd64) op_kw="linux-amd64" ;;
        i386|i686)        op_kw="linux-386" ;;
        armv8|arm64|aarch64) op_kw="linux-arm64" ;;
      esac
      say "正在从 GitHub 获取 opera-proxy 最新链接..."
      local op_url
      op_url="$(extract_github_url "Snawoot/opera-proxy" "opera-proxy.*$op_kw")"
      if [[ -n "$op_url" ]]; then
        download_bin "opera-linux" "$op_url"
      else
        say "[ERROR] 无法从 GitHub 找到 opera-proxy ($op_kw) 的直链，作者可能已删除或改名。"
        exit 1
      fi
    fi
    operaport="$(get_free_port)"
    screen -dmUS opera ./opera-linux -country "${country:-AM}" -socks-mode -bind-address "127.0.0.1:${operaport}"
    sleep 1
  fi

  [[ -z "${wsport:-}" ]] && wsport="$(get_free_port)"

  if [[ -z "${token:-}" ]]; then
    if [[ "${opera:-0}" == "1" ]]; then
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}" -f "socks5://127.0.0.1:${operaport}"
    else
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}"
    fi
  else
    if [[ "${opera:-0}" == "1" ]]; then
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}" -token "$token" -f "socks5://127.0.0.1:${operaport}"
    else
      screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}" -token "$token"
    fi
  fi

  metricsport="$(get_free_port)"
  ./cloudflared-linux update >/dev/null 2>&1 || true

  screen -dmUS argo ./cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel \
    --url "127.0.0.1:${wsport}" --metrics "0.0.0.0:${metricsport}"

  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    screen -dmUS cfbind ./cloudflared-linux --edge-ip-version "$ips" tunnel run --token "$cf_tunnel_token"
  fi

  TRY_DOMAIN=""
  for _ in $(seq 1 60); do
    RESP="$(curl -s "http://127.0.0.1:${metricsport}/metrics" || true)"
    if echo "$RESP" | grep -q 'userHostname='; then
      TRY_DOMAIN="$(echo "$RESP" | sed -nE 's/.*userHostname="?https?:\/\/([^"]+)".*/\1/p' | head -n1 || true)"
      break
    fi
    sleep 1
  done

  save_config; clear
  say "=============================="; say "梭哈模式：启动完成"
  say "------------------------------"; say "本地监听 ws 端口: ${wsport}"

  if [[ -n "$TRY_DOMAIN" ]]; then
    [[ -z "${token:-}" ]] && say "【临时域名 Quick Tunnel】 ${TRY_DOMAIN}:443" || say "【临时域名 Quick Tunnel】 ${TRY_DOMAIN}:443   身份令牌: ${token}"
  else
    say "【临时域名 Quick Tunnel】未解析到"
  fi

  if [[ "${bind_enable:-0}" == "1" ]]; then
    if [[ -n "${bind_domain:-}" ]]; then
      [[ -z "${token:-}" ]] && say "【绑定域名 Named Tunnel】 ${bind_domain}:443" || say "【绑定域名 Named Tunnel】 ${bind_domain}:443   身份令牌: ${token}"
    else
      say "【绑定域名 Named Tunnel】已启用"
    fi
  else
    say "【绑定域名 Named Tunnel】未启用"
  fi

  PUBIP="$(curl -4 -s https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2 || true)"
  say "metrics: http://${PUBIP:-<你的公网IP>}:${metricsport}/metrics"
  say "=============================="
  self_check "${bind_domain:-}" "${TRY_DOMAIN:-}" "${wsport:-}"
}

view_domains(){
  clear
  if load_config; then
    say "=============================="; say "域名绑定查看（读取上次启动保存的配置）"
    say "------------------------------"; say "本地监听 ws 端口: ${wsport:-未知}"

    if [[ -n "${try_domain:-}" ]]; then
      [[ -z "${token:-}" ]] && say "【临时域名 Quick Tunnel】 ${try_domain}:443" || say "【临时域名 Quick Tunnel】 ${try_domain}:443   身份令牌: ${token}"
    else
      say "【临时域名 Quick Tunnel】无记录"
    fi

    if [[ "${bind_enable:-0}" == "1" ]]; then
      if [[ -n "${bind_domain:-}" ]]; then
        [[ -z "${token:-}" ]] && say "【绑定域名 Named Tunnel】 ${bind_domain}:443" || say "【绑定域名 Named Tunnel】 ${bind_domain}:443   身份令牌: ${token}"
      else
        say "【绑定域名 Named Tunnel】已启用"
      fi
    else
      say "【绑定域名 Named Tunnel】未启用"
    fi
    say "=============================="
    self_check "${bind_domain:-}" "${try_domain:-}" "${wsport:-}"
  else
    say "未找到上次启动的配置记录，请先运行选项1启动服务"
  fi
}

# ------------- main -------------
idx="$(os_index)"
need_cmd screen "$idx"; need_cmd curl "$idx"; need_cmd sed "$idx"; need_cmd grep "$idx"
need_cmd awk "$idx"; need_cmd ss "$idx" || true; need_cmd openssl "$idx" || true; need_cmd nc "$idx" || true

clear
say "梭哈模式不需要自己提供域名,使用CF ARGO QUICK TUNNEL创建快速链接"
say "梭哈模式在重启或者脚本再次运行后失效,如果需要使用需要再次运行创建"
printf "\n梭哈是一种智慧!!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n\n"
say "1.梭哈模式"
say "2.停止服务"
say "3.清空缓存"
say "4.域名绑定查看"
printf "0.退出脚本\n\n"

read -r -p "请选择模式(默认1):" mode || true
mode="${mode:-1}"

if [[ "$mode" == "1" ]]; then
  read -r -p "是否启用opera前置代理(0.不启用[默认],1.启用):" opera || true
  opera="${opera:-0}"
  if [[ "$opera" == "1" ]]; then
    say "注意:opera前置代理仅支持AM,AS,EU地区"
    read -r -p "请输入opera前置代理的国家代码(默认AM):" country || true
    country="${country:-AM}"
    country="$(echo "$country" | tr '[:lower:]' '[:upper:]')"
    if [[ "$country" != "AM" && "$country" != "AS" && "$country" != "EU" ]]; then
      say "请输入正确的opera前置代理国家代码"; exit 1
    fi
  fi

  read -r -p "请选择cloudflared连接模式IPV4或者IPV6(输入4或6,默认4):" ips || true
  ips="${ips:-4}"
  if [[ "$ips" != "4" && "$ips" != "6" ]]; then
    say "请输入正确的连接模式"; exit 1
  fi

  read -r -p "请设置x-tunnel的token(可留空):" token || true
  token="${token:-}"

  read -r -p "是否固定ws端口(0.不固定[默认],1.固定):" fixp || true
  fixp="${fixp:-0}"
  if [[ "$fixp" == "1" ]]; then
    read -r -p "请输入固定ws端口(默认 12345):" wsport || true
    wsport="${wsport:-12345}"
  else
    wsport=""
  fi

  read -r -p "是否启用绑定自定义域名(Named Tunnel)(0.不启用[默认],1.启用):" bind_enable || true
  bind_enable="${bind_enable:-0}"
  cf_tunnel_token=""; bind_domain=""
  if [[ "$bind_enable" == "1" ]]; then
    read -r -p "请输入 Cloudflare Tunnel Token(必填):" cf_tunnel_token || true
    if [[ -z "${cf_tunnel_token:-}" ]]; then
      bind_enable=0
    else
      read -r -p "请输入绑定域名(可留空):" bind_domain || true
      bind_domain="${bind_domain:-}"
      if [[ "$fixp" == "0" ]]; then
        read -r -p "是否现在固定端口？(1.是[推荐], 0.否): " force_fix || true
        force_fix="${force_fix:-1}"
        if [[ "$force_fix" == "1" ]]; then
          fixp=1
          read -r -p "请输入固定 ws 端口(默认 12345):" wsport || true
          wsport="${wsport:-12345}"
        fi
      fi
    fi
  fi

  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel; stop_screen opera; stop_screen argo; stop_screen cfbind
  remove_config; clear; sleep 1
  quicktunnel

elif [[ "$mode" == "2" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel; stop_screen opera; stop_screen argo; stop_screen cfbind
  remove_config; clear
  say "已停止服务（配置记录已清除）"

elif [[ "$mode" == "3" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel; stop_screen opera; stop_screen argo; stop_screen cfbind
  rm -f cloudflared-linux x-tunnel-linux opera-linux
  remove_config; clear
  say "已清空缓存（配置记录已清除）"

elif [[ "$mode" == "4" ]]; then
  view_domains
else
  say "退出成功"; exit 0
fi
