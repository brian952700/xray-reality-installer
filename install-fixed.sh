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

ask_port() {
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
}

make_initial_config() {
  DOMAIN="www.apple.com"
  UUID="78c3760d-daa3-4027-a278-f5d8fe015554"
  PRIVATE_KEY="yDhLeC8fLfEX6mls4gEZPCMshJm9HboURhXTaZaxR1o"
  SHORT_ID="5e10da8e6afc9978"
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
}

write_service() {
  if [ "$SERVICE_MANAGER" = systemd ]; then
    cat > "$STAGE/service" << 'UNIT'
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
  else
    cat > "$STAGE/service" << 'RC'
#!/sbin/openrc-run
name=xray
description="Xray VLESS REALITY Service"
supervisor=supervise-daemon
command=/opt/xray/xray
command_args="run -c /opt/xray/config.json"
pidfile=/run/xray.pid
respawn_delay=2
respawn_max=5
respawn_period=60
depend() {
    need net
}
RC
  fi
}

ensure_dependencies() {
  missing=
  if [ "$SERVICE_MANAGER" = openrc ]; then
    for package in ca-certificates curl unzip gcompat python3; do
      if ! apk info -e "$package" >/dev/null 2>&1; then
        missing="$missing $package"
      fi
    done
    if [ -n "$missing" ]; then
      # Packages come from the fixed list above.
      # shellcheck disable=SC2086
      run_quiet '安装缺少的依赖' apk add --no-cache $missing
    fi
  else
    for package in ca-certificates curl unzip python3; do
      if [ "$(dpkg-query -W -f '${Status}' "$package" 2>/dev/null || true)" != 'install ok installed' ]; then
        missing="$missing $package"
      fi
    done
    if [ -n "$missing" ]; then
      run_quiet '更新软件源索引' apt-get update
      # shellcheck disable=SC2086
      run_quiet '安装缺少的依赖' env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing
    fi
  fi
  if [ -z "$missing" ]; then
    ok '所需依赖已齐全'
  fi
}

deploy() {
  XRAY_INSTALL_VERSION="$XRAY_VERSION" python3 - "$STAGE" "$SERVICE_MANAGER" <<'PY'
from contextlib import contextmanager
import filecmp
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import time

stage = Path(sys.argv[1])
systemd = sys.argv[2] == "systemd"
root = Path("/opt/xray")
service = Path("/etc/systemd/system/xray.service" if systemd else "/etc/init.d/xray")
binary = root / "xray"
config = root / "config.json"
xy = Path("/usr/local/bin/xy")
owned = root / ".installer-owned"
owner = "brian952700/xray-reality-installer"
transaction = root.parent / ".xray-install-transaction"
journal = transaction / "journal.json"
uninstall_pending = root.parent / ".xray-uninstall-pending"
paths = {"binary": binary, "config": config, "service": service, "xy": xy, "owned": owned}
manager = runpy.run_path(str(stage / "xy"))
lock_wait = 30


@contextmanager
def locked(path):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+b") as lock:
        deadline = time.monotonic() + lock_wait
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("另一项 Xray 管理操作正在执行，请稍后重试。") from None
                time.sleep(0.1)
        yield


def command(*args, check=True, capture=False, timeout=45):
    return subprocess.run(
        args, check=check, capture_output=capture, text=True, stdin=subprocess.DEVNULL,
        timeout=timeout,
    )


def active():
    args = ("systemctl", "is-active", "xray.service") if systemd else ("rc-service", "xray", "status")
    result = command(*args, check=False, capture=True, timeout=5)
    if systemd and result.stdout.strip() in {"activating", "deactivating", "reloading"}:
        raise RuntimeError("Xray 服务正在切换状态，请稍后重试。")
    if systemd and result.returncode not in {0, 3, 4}:
        raise RuntimeError(result.stderr.strip() or "无法查询 Xray 服务状态。")
    return result.returncode == 0


def boot_enabled():
    if systemd:
        result = command("systemctl", "is-enabled", "xray.service", check=False, capture=True, timeout=5)
        state = result.stdout.strip()
        if state not in {"enabled", "enabled-runtime", "static", "indirect", "disabled", "not-found", ""}:
            raise RuntimeError(f"Xray 自启状态无法安全调整：{state}")
        if not state and service.exists():
            raise RuntimeError(result.stderr.strip() or "无法查询 Xray 自启状态。")
        return state == "enabled"
    return Path("/etc/runlevels/default/xray").is_symlink()


def set_boot(enable):
    if systemd:
        command("systemctl", "enable" if enable else "disable", "xray.service")
    else:
        command("rc-update", "add" if enable else "del", "xray", "default")
        command("rc-update", "-u", "show", "default")


def service_action(action):
    if systemd:
        command("systemctl", action, "xray.service")
    else:
        command("rc-service", "xray", action)


def reload_service():
    if systemd:
        command("systemctl", "daemon-reload")
    else:
        command("rc-update", "-u", "show", "default")


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def place(source, target, mode=None):
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    fd, name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    tmp = Path(name)
    try:
        os.close(fd)
        shutil.copy2(source, tmp)
        if mode is not None:
            tmp.chmod(mode)
        with tmp.open("rb") as file:
            os.fsync(file.fileno())
        os.replace(tmp, target)
        sync_dir(target.parent)
    finally:
        tmp.unlink(missing_ok=True)


def remove(path):
    if path.exists() or path.is_symlink():
        path.unlink()
        sync_dir(path.parent)


def clear_journal():
    # Once the journal disappears, any remaining copies can be deleted on the next run.
    remove(journal)
    try:
        shutil.rmtree(transaction)
        sync_dir(transaction.parent)
    except OSError as error:
        print(f"清理事务备份失败：{error}。下次安装时会重试清理。", file=sys.stderr)


def restore():
    saved = json.loads(journal.read_text(encoding="utf-8"))
    # A timed-out service command can still have work queued in the service manager.
    if saved["service_changed"]:
        if systemd:
            command("systemctl", "stop", "xray.service", check=False)
            if active():
                raise RuntimeError("回滚前无法停止 Xray 服务。")
        elif service.exists() and active():
            service_action("stop")
    if saved["boot_change"] and service.exists() and boot_enabled() != saved["enabled"]:
        set_boot(saved["enabled"])
    for key, existed in saved["files"].items():
        if existed:
            place(transaction / key, paths[key])
        else:
            remove(paths[key])
    if saved["service_changed"]:
        reload_service()
        if saved["active"]:
            service_action("start")
            wait_for_service(saved["port"])
    if not saved["had_root"] and root.is_dir():
        # Leave any files added by the administrator or another tool untouched.
        if not any(root.iterdir()):
            root.rmdir()
            sync_dir(root.parent)
    clear_journal()


def inbound_port(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    inbounds = [entry for entry in data["inbounds"] if entry.get("protocol") == "vless"]
    if len(inbounds) != 1:
        raise ValueError("用户管理需要恰好一个 VLESS 入站。")
    port = inbounds[0].get("port")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("VLESS 入站需要使用单一 TCP 端口。")
    return port


def refuse_downgrade():
    pinned = os.environ.get("XRAY_INSTALL_VERSION")
    if not pinned:
        return
    try:
        result = command(str(binary), "version", check=False, capture=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return
    installed = re.match(r"Xray v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:\s|$)", result.stdout)
    if result.returncode == 0 and installed:
        existing_version = tuple(map(int, installed.groups()))
        pinned_version = tuple(map(int, pinned.removeprefix("v").split(".")))
        if existing_version > pinned_version:
            display = ".".join(installed.groups())
            raise ValueError(f"当前 Xray {display} 高于安装器版本 {pinned}，已停止以避免降级。")


def wait_for_service(port):
    manager["wait_for_listener"]([port], timeout=12)
    if not active():
        raise RuntimeError("检测到监听后，Xray 服务仍未保持运行。")


def abort_signal(signum, frame):
    raise InterruptedError(f"收到信号 {signum}，安装已中断。")


def prepare_journal(changes, *, port, service_changed, was_active, was_enabled, boot_change):
    transaction.mkdir(mode=0o700)
    originals = {}
    for key, (target, _, _) in changes.items():
        originals[key] = target.exists()
        if originals[key]:
            place(target, transaction / key)
    data = dict(
        files=originals, port=port, service_changed=service_changed,
        active=was_active, enabled=was_enabled, boot_change=boot_change, had_root=root.exists(),
    )
    staged_journal = stage / "journal.json"
    staged_journal.write_text(json.dumps(data), encoding="utf-8")
    place(staged_journal, journal, 0o600)
    sync_dir(transaction.parent)


def update():
    if uninstall_pending.exists() or uninstall_pending.is_symlink():
        if (uninstall_pending.is_symlink() or not uninstall_pending.is_file()
                or uninstall_pending.read_text(encoding="utf-8").strip() != owner
                or any(path.exists() or path.is_symlink() for path in (root, service, xy))):
            raise RuntimeError("发现未完成的卸载。请先用 xy 继续卸载，再运行安装脚本。")
        # Uninstall can be interrupted after removing xy, before clearing its record.
        remove(uninstall_pending)
    if root.is_symlink() or (root.exists() and not root.is_dir()):
        raise RuntimeError("Xray 安装目录不是预期的目录。")
    if transaction.is_symlink():
        raise RuntimeError("Xray 事务目录不能是符号链接。")
    if transaction.exists():
        if journal.exists():
            print("检测到未完成的安装事务，正在恢复原状态…", flush=True)
            restore()
        else:
            shutil.rmtree(transaction)
            sync_dir(transaction.parent)

    for target in paths.values():
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise RuntimeError(f"安装路径不是普通文件：{target}")
    if service.exists():
        definition = service.read_text(encoding="utf-8")
        expected = f"ExecStart={binary} run " if systemd else f"command={binary}\n"
        if expected not in definition:
            raise RuntimeError("现有 Xray 服务不属于此安装器。")
    if owned.exists() and owned.read_text(encoding="utf-8").strip() != owner:
        raise RuntimeError("Xray 安装目录的归属标记不匹配。")
    if xy.exists() and not manager["xy_is_owned"]():
        raise RuntimeError("现有 /usr/local/bin/xy 不属于此安装器。")

    previous_install = config.exists()
    candidate = config if previous_install else stage / "config.json"
    if not candidate.exists():
        raise RuntimeError("没有可用的配置，请重新运行安装并输入端口。")
    port = inbound_port(candidate)
    command(str(stage / "xray"), "run", "-test", "-c", str(candidate), timeout=20)

    staged_marker = stage / "owned"
    staged_marker.write_text(owner + "\n", encoding="utf-8")
    desired = {
        "binary": (binary, stage / "xray", 0o755),
        "xy": (xy, stage / "xy", 0o755),
        "owned": (owned, staged_marker, 0o600),
    }
    if not previous_install:
        desired["config"] = (config, candidate, 0o600)
    if not service.exists():
        desired["service"] = (service, stage / "service", 0o644 if systemd else 0o755)

    changes = {
        key: item for key, item in desired.items()
        if not item[0].exists() or not filecmp.cmp(item[0], item[1], shallow=False)
        or item[0].stat().st_mode & 0o777 != item[2]
    }
    if binary.exists() and "binary" in changes:
        refuse_downgrade()
    was_active = active()
    was_enabled = boot_enabled()
    if not service.exists() and (was_active or was_enabled):
        raise RuntimeError("检测到由其他路径管理的 Xray 服务。")
    start_needed = not previous_install or not service.exists()
    restart_needed = was_active and "binary" in changes
    service_changed = start_needed or restart_needed
    boot_change = start_needed and not was_enabled
    if changes or service_changed:
        try:
            prepare_journal(
                changes, port=port, service_changed=service_changed, was_active=was_active,
                was_enabled=was_enabled, boot_change=boot_change,
            )
            for target, source, mode in changes.values():
                place(source, target, mode)
            if "service" in changes:
                reload_service()
            if service_changed:
                try:
                    service_action("restart" if was_active else "start")
                    wait_for_service(port)
                except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
                    if systemd:
                        try:
                            command("journalctl", "-u", "xray.service", "-n", "20", "--no-pager", check=False, timeout=5)
                        except (OSError, subprocess.SubprocessError):
                            pass
                    raise
            if boot_change:
                set_boot(True)
            clear_journal()
        except (Exception, KeyboardInterrupt):
            if journal.exists():
                try:
                    restore()
                    print("已恢复安装前的文件和服务状态。", file=sys.stderr)
                except (Exception, KeyboardInterrupt) as recovery:
                    print(f"自动回滚失败：{recovery}。事务备份保留在 {transaction}，可重新运行安装重试回滚。", file=sys.stderr)
            raise

    if not previous_install:
        (stage / "show-links").touch()
    print(f"\n── {'升级完成' if previous_install else '安装完成'} ──\n")
    print(f"  监听端口    {port} / TCP")
    print(f"  配置文件    {config}")
    print("  用户管理    xy（也可运行 /usr/local/bin/xy）")
    print(f"  服务状态    {'运行中' if was_active or service_changed else '保持停止'}")
    print(f"  开机自启    {'启用' if was_enabled or boot_change else '保持关闭'}")
    print(f"  请在主机防火墙和云安全组放行 TCP {port}。", flush=True)


signal.signal(signal.SIGTERM, abort_signal)
signal.signal(signal.SIGHUP, abort_signal)
try:
    with locked(root.parent / ".xray-install.lock"):
        if root.is_dir() and not root.is_symlink():
            # Also coordinate with an older xy that is already saving a change.
            with locked(root / ".users.lock"):
                update()
        else:
            update()
except (Exception, KeyboardInterrupt) as error:
    print(f"安装未完成：{error}", file=sys.stderr)
    sys.exit(1)
PY
}

interrupted_first_install() {
  journal=/opt/.xray-install-transaction/journal.json
  [ -f "$journal" ] && command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    sys.exit(0 if json.load(source)["files"].get("config") is False else 1)' "$journal" 2>/dev/null
}

main() {
  printf '\n%s╭──────────────────────────────────────────╮\n│          Xray · REALITY 安装助手          │\n╰──────────────────────────────────────────╯%s\n' "$C_BLUE" "$C_RESET"
  [ "$(id -u)" -eq 0 ] || fail '请使用 root 执行。'
  [ -r /etc/os-release ] || fail '无法识别系统。'
  . /etc/os-release
  section '[1/5] 检查运行环境'
  case "$ID" in
    alpine)
      [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1 || fail '需要运行 OpenRC 的 Alpine 主机。'
      SERVICE_MANAGER=openrc
      ;;
    debian)
      MAJOR=${VERSION_ID%%.*}
      case "$MAJOR" in ''|*[!0-9]*) fail '无法识别 Debian 版本。';; esac
      [ "$MAJOR" -ge 12 ] || fail '仅支持 Debian 12 及以上版本。'
      [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 || fail '需要运行 systemd 的 Debian 主机。'
      SERVICE_MANAGER=systemd
      ;;
    *) fail "暂不支持此系统：$ID" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)
      XRAY_ARCH=64
      XRAY_SHA256=b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82 ;;
    aarch64|arm64)
      XRAY_ARCH=arm64-v8a
      XRAY_SHA256=64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be ;;
    armv7*)
      XRAY_ARCH=arm32-v7a
      XRAY_SHA256=19c51e08a6562705fb1cb032a84fd87df21d7e27b194f035be7e754dbe3a97b3 ;;
    s390x)
      XRAY_ARCH=s390x
      XRAY_SHA256=5657912fbd7429d8a0202dccd8815a297fe49d009216a5359af238ebb6f0db4c ;;
    *) fail "不支持的 CPU 架构：$(uname -m)" ;;
  esac
  ok "${PRETTY_NAME:-$ID} / $(uname -m)"
  mkdir -p /opt
  STAGE=$(mktemp -d /opt/.xray-install-stage.XXXXXX)
  trap 'rm -rf "$STAGE"' EXIT
  trap 'exit 1' HUP INT TERM

  if interrupted_first_install || [ ! -f /opt/xray/config.json ]; then
    ask_port
    make_initial_config
  else
    ok '检测到已有安装，将保留现有端口和用户'
  fi

  section '[2/5] 检查所需依赖'
  ensure_dependencies

  section '[3/5] 下载并校验文件'
  XRAY_VERSION=v26.11.9
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-$XRAY_ARCH.zip"
  XY_URL='https://raw.githubusercontent.com/brian952700/xray-reality-installer/6318422748aef09e7d919f65fa53d955fca1ef7d/xray-users.py'
  XY_SHA256='22e6b3674af660976fbbd967aeb6d8fe8e5cbf0b18d21fd07fce2e93719a296d'
  run_quiet "下载 Xray $XRAY_VERSION" curl -fsSL --retry 2 --retry-max-time 120 --connect-timeout 10 --max-time 90 "$XRAY_URL" -o "$STAGE/xray.zip"
  run_quiet '下载用户管理脚本' curl -fsSL --retry 2 --retry-max-time 40 --connect-timeout 10 --max-time 25 "$XY_URL" -o "$STAGE/xy"
  printf '%s  %s\n' "$XRAY_SHA256" "$STAGE/xray.zip" "$XY_SHA256" "$STAGE/xy" > "$STAGE/checksums"
  run_quiet '校验 SHA-256' sha256sum -c "$STAGE/checksums"
  run_quiet '解压 Xray' unzip -q "$STAGE/xray.zip" xray -d "$STAGE"
  chmod 755 "$STAGE/xray"
  run_quiet '验证用户管理脚本' python3 "$STAGE/xy" --help
  write_service

  section '[4/5] 验证配置并更新服务'
  deploy

  section '[5/5] 用户连接链接'
  if [ ! -f "$STAGE/show-links" ]; then
    printf '  运行 xy 可查看现有用户和连接链接。\n'
  elif ! /usr/local/bin/xy list; then
    printf '  %s!%s 暂时无法生成链接，请稍后使用 xy 查看。\n' "$C_YELLOW" "$C_RESET" >&2
  fi
  if [ "$SERVICE_MANAGER" = systemd ]; then
    printf '\n  查看状态：systemctl status xray\n  查看日志：journalctl -u xray -n 50 --no-pager\n'
  else
    printf '\n  查看状态：rc-service xray status\n'
  fi
}

main "$@"
