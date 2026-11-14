#!/bin/sh
# Alpine Linux (OpenRC) / Debian 12+ (systemd)
# root 执行: sh install-fixed.sh
# 内含固定私钥，请勿公开；所有机器共用凭据。
set -eu
umask 077
NO_COLOR_VALUE=${NO_COLOR-}
TERM_VALUE=${TERM:-dumb}
C_BLUE= C_GREEN= C_YELLOW= C_RED= C_RESET=
if [ -z "$NO_COLOR_VALUE" ] && [ "$TERM_VALUE" != dumb ] && (test -t 1 || test -t 2); then
  C_BLUE=$(printf '\033[36m'); C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m'); C_RED=$(printf '\033[31m'); C_RESET=$(printf '\033[0m')
fi
section() { printf '\n%s── %s ──%s\n\n' "$C_BLUE" "$*" "$C_RESET"; }
ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { printf '\n  %s✗%s %s\n\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
run_quiet() {
  TASK_LABEL=$1; shift
  printf '  %s…%s 正在%s，请稍候\n' "$C_BLUE" "$C_RESET" "$TASK_LABEL"
  if "$@" </dev/null >"$STAGE/task.log" 2>&1; then
    ok "$TASK_LABEL"
  else
    printf '\n%s执行失败：%s%s\n' "$C_RED" "$TASK_LABEL" "$C_RESET" >&2
    cat "$STAGE/task.log" >&2
    fail '安装未完成，请根据以上日志排查后重试。'
  fi
}
printf '\n%s╭──────────────────────────────────────────╮\n│          Xray · REALITY 安装助手          │\n╰──────────────────────────────────────────╯%s\n' "$C_BLUE" "$C_RESET"
[ "$(id -u)" -eq 0 ] || fail '请使用 root 执行。'
[ -r /etc/os-release ] || fail '无法识别系统。'
. /etc/os-release
printf "\n  系统  %s\n  架构  %s\n" "${PRETTY_NAME:-$ID}" "$(uname -m)"
section "设置监听端口"
printf "  请输入 10000–65535 的整数端口，不能为空。\n\n"
# 从终端读取，避免 curl | sh 时把脚本内容当作输入。
PORT=
if [ -r /dev/tty ] && [ -w /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
  while :; do
    printf '  %s› 监听端口：%s' "$C_BLUE" "$C_RESET" > /dev/tty
    if ! IFS= read -r INPUT_PORT < /dev/tty; then
      fail '无法读取端口，请在交互式终端中重新执行。'
    fi
    case "$INPUT_PORT" in
      *[!0-9]*|'') printf '\n  %s!%s 端口必须是整数，不能为空，请重新输入。\n\n' "$C_YELLOW" "$C_RESET" > /dev/tty; continue ;;
    esac
    # 去除前导零，避免 JSON 数字不合法或被解释为八进制。
    INPUT_PORT=$(printf '%s' "$INPUT_PORT" | sed 's/^0*//')
    if [ -n "$INPUT_PORT" ] && [ "${#INPUT_PORT}" -le 5 ] && [ "$INPUT_PORT" -ge 10000 ] && [ "$INPUT_PORT" -le 65535 ]; then
      PORT=$INPUT_PORT
      break
    fi
    printf '\n  %s!%s 端口必须在 10000–65535 之间，请重新输入。\n\n' "$C_YELLOW" "$C_RESET" > /dev/tty
  done
else
  fail '未检测到交互式终端，必须在终端中输入端口后才能安装。'
fi

printf '\n  %s✓%s 已选择端口 %s\n\n%s── [1/6] 检查运行环境 ──%s\n\n' \
  "$C_GREEN" "$C_RESET" "$PORT" "$C_BLUE" "$C_RESET"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 1' HUP INT TERM
case "$ID" in
  alpine)
    [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1 || fail '需要运行 OpenRC 的 Alpine 主机。'
    ok 'Alpine / OpenRC 环境检查通过'
    section '[2/6] 安装所需依赖'
    run_quiet '安装系统依赖' apk add --no-cache ca-certificates curl unzip gcompat
    SERVICE_MANAGER=openrc
    ;;
  debian)
    MAJOR=${VERSION_ID%%.*}
    case "$MAJOR" in ''|*[!0-9]*) fail '无法识别 Debian 版本。';; esac
    [ "$MAJOR" -ge 12 ] || fail '仅支持 Debian 12 及以上版本。'
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 || fail '需要运行 systemd 的 Debian 主机。'
    ok 'Debian / systemd 环境检查通过'
    section '[2/6] 安装所需依赖'
    run_quiet '更新软件源索引' apt-get update
    run_quiet '安装系统依赖' env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip
    SERVICE_MANAGER=systemd
    ;;
  *) fail "暂不支持此系统：$ID" ;;
esac
DOMAIN="www.apple.com"
UUID="78c3760d-daa3-4027-a278-f5d8fe015554"
PRIVATE_KEY="yDhLeC8fLfEX6mls4gEZPCMshJm9HboURhXTaZaxR1o"
PUBLIC_KEY="B2h9Dp8m8-hwwyFnlXi0Pj2zwbtD6vRQGmBbyciM_TE"
SHORT_ID="5e10da8e6afc9978"



case "$(uname -m)" in
  x86_64|amd64) XRAY_ARCH=64 ;;
  aarch64|arm64) XRAY_ARCH=arm64-v8a ;;
  armv7*) XRAY_ARCH=arm32-v7a ;;
  s390x) XRAY_ARCH=s390x ;;
  *) fail "不支持的 CPU 架构：$(uname -m)" ;;
esac
section '[3/6] 下载 Xray'
XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
run_quiet '下载 Xray' curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 "$XRAY_URL" -o "$STAGE/xray.zip"
run_quiet '解压安装文件' unzip -q "$STAGE/xray.zip" -d "$STAGE"
chmod 755 "$STAGE/xray"
section '[4/6] 生成并验证配置'
cat > "$STAGE/config.json" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${DOMAIN}:443",
          "serverNames": [
            "${DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF


chmod 600 "$STAGE/config.json"
run_quiet '验证 Xray 配置' "$STAGE/xray" run -test -c "$STAGE/config.json"
mkdir -p /opt/xray
# 检查通过后替换，避免直接覆盖运行中的二进制文件。
cp "$STAGE/xray" /opt/xray/xray.new
chmod 755 /opt/xray/xray.new
mv -f /opt/xray/xray.new /opt/xray/xray
cp "$STAGE/config.json" /opt/xray/config.json.new
mv -f /opt/xray/config.json.new /opt/xray/config.json
ok '程序和配置已就绪'
section '[5/6] 配置系统服务'
if [ "$SERVICE_MANAGER" = systemd ]; then
  cat > /etc/systemd/system/xray.service << 'UNIT'
[Unit]
Description=Xray VLESS REALITY Service
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
ExecStart=/opt/xray/xray run -c /opt/xray/config.json
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 /etc/systemd/system/xray.service
  run_quiet '加载服务定义' systemctl daemon-reload
  run_quiet '启用开机自启' systemctl enable xray
  run_quiet '启动 Xray' systemctl restart xray
  sleep 2
  systemctl is-active --quiet xray || {
    journalctl -u xray -n 30 --no-pager >&2
    fail 'Xray 启动失败，请查看以上日志。'
  }
else
  cat > /etc/init.d/xray << 'RC'
#!/sbin/openrc-run
name=xray
description="Xray VLESS REALITY Service"
supervisor=supervise-daemon
command=/opt/xray/xray
command_args="run -c /opt/xray/config.json"
pidfile=/run/xray.pid
depend() {
    need net
}
RC
  chmod 755 /etc/init.d/xray
  run_quiet '启用开机自启' rc-update add xray default
  run_quiet '刷新 OpenRC 依赖缓存' rc-update -u show default
  if rc-service xray status >/dev/null 2>&1; then
    run_quiet '重启 Xray' rc-service xray restart
  else
    run_quiet '启动 Xray' rc-service xray start
  fi
  sleep 2
  rc-service xray status || fail 'Xray 启动失败。'
fi
ok '服务正在运行，已设置开机自启'
printf '\n%s── [6/6] 获取服务器地址 ──%s\n\n  正在查询公网 IPv4，请稍候…\n' "$C_BLUE" "$C_RESET"
SERVER_IP=$(curl -fsS4 --connect-timeout 5 --max-time 10 https://api.ipify.org || curl -fsS4 --connect-timeout 5 --max-time 10 https://ifconfig.me/ip || true)
if ! printf '%s\n' "$SERVER_IP" | awk -F. 'NF!=4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i>255) exit 1}'; then
  SERVER_IP=YOUR_SERVER_IP
fi
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Xray-REALITY-${DOMAIN}"
IP_NOTICE=
if [ "$SERVER_IP" = YOUR_SERVER_IP ]; then
  IP_NOTICE='  无法获取公网 IPv4，请将链接中的 YOUR_SERVER_IP 替换为实际地址。
'
fi

if [ "$SERVICE_MANAGER" = systemd ]; then
  SERVICE_COMMANDS='  查看状态：systemctl status xray
  重启服务：systemctl restart xray
  停止服务：systemctl stop xray
  查看日志：journalctl -u xray -n 50 --no-pager'
else
  SERVICE_COMMANDS='  查看状态：rc-service xray status
  重启服务：rc-service xray restart
  停止服务：rc-service xray stop'
fi

printf '
%s── 安装完成 ──%s

  %s✓%s 服务正在运行，已设置开机自启

  服务器地址  %s
  监听端口    %s / TCP
  目标域名    %s
  配置文件    /opt/xray/config.json

%s── 客户端连接链接 ──%s

%s

%s%s  请在主机防火墙和云安全组放行 TCP %s。%s

%s── 服务管理 ──%s

%s

' "$C_BLUE" "$C_RESET" "$C_GREEN" "$C_RESET" \
  "$SERVER_IP" "$PORT" "$DOMAIN" "$C_BLUE" "$C_RESET" "$VLESS_LINK" \
  "$C_YELLOW" "$IP_NOTICE" "$PORT" "$C_RESET" \
  "$C_BLUE" "$C_RESET" "$SERVICE_COMMANDS"
