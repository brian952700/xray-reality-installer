#!/usr/bin/env python3
# Managed by brian952700/xray-reality-installer.
"""Manage named users in an installed Xray VLESS inbound."""
import argparse
from contextlib import contextmanager
import fcntl
from hashlib import sha256
from ipaddress import IPv4Address, ip_address
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import quote, urlencode

ROOT = Path("/opt/xray")
CONFIG = ROOT / "config.json"
BINARY = ROOT / "xray"
LOCK = Path("/opt/.xray-install.lock")
UNINSTALL_PENDING = Path("/opt/.xray-uninstall-pending")
INSTALL_TRANSACTION = Path("/opt/.xray-install-transaction")
XY = Path("/usr/local/bin/xy")
OWNER = "brian952700/xray-reality-installer"
XY_HEADER = f"# Managed by {OWNER}.".encode()
LEGACY_XY_SHA256 = "ab20385585725b092443549221e7105c30746876bff8ce0e610ebfdbf0e3f549"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")
HOST_LABEL = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")
IP_CACHE_SECONDS = 600
SERVICE_ERRORS = (OSError, ValueError, subprocess.SubprocessError)


@contextmanager
def operation_lock(shared=False, timeout=15):
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
    with os.fdopen(os.open(LOCK, flags, 0o600), "rb") as lock:
        mode = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(lock, mode | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("另一个 Xray 管理操作尚未完成，请稍后重试。") from None
                time.sleep(min(0.2, remaining))
        yield


def service_manager():
    if Path("/run/openrc").is_dir():
        return "openrc"
    if Path("/run/systemd/system").is_dir():
        return "systemd"
    raise ValueError("未找到 OpenRC 或 systemd。")


def command(*args, timeout=30, check=True, quiet=False):
    return subprocess.run(
        args, check=check, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.DEVNULL if quiet else None,
        timeout=timeout,
    )


def managed_pids(manager, timeout):
    if manager == "systemd":
        try:
            result = subprocess.run(
                ("systemctl", "show", "--property=MainPID", "--value", "xray.service"),
                capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL,
                check=True,
            )
            pid = result.stdout.strip()
            return [pid] if pid.isdecimal() and pid != "0" else []
        except subprocess.TimeoutExpired:
            return []

    try:
        supervisor = Path("/run/xray.pid").read_text(encoding="ascii").strip()
        if not supervisor.isdecimal():
            return []
        children = Path(f"/proc/{supervisor}/task/{supervisor}/children")
        try:
            return children.read_text(encoding="ascii").split()
        except FileNotFoundError:
            # Custom kernels may omit the optional /proc children file.
            return openrc_children(supervisor)
    except OSError:
        return []


def openrc_children(supervisor):
    pids = []
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            with (process / "status").open(encoding="utf-8", errors="replace") as status:
                for line in status:
                    if line.startswith("PPid:"):
                        if line.split()[1] == supervisor:
                            pids.append(process.name)
                        break
        except OSError:
            continue
    return pids


def listener_pid(ports, pids):
    """Return the PID of Xray if it owns a listening socket on each port."""
    sockets = {}
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(table, encoding="ascii") as source:
                next(source, None)
                for line in source:
                    fields = line.split()
                    if len(fields) < 10 or fields[3] != "0A":
                        continue
                    port = int(fields[1].rsplit(":", 1)[1], 16)
                    if port in ports:
                        sockets[f"socket:[{fields[9]}]"] = port
        except FileNotFoundError:
            continue
    if not ports.issubset(sockets.values()):
        return None

    executable = str(BINARY.resolve())
    for pid in pids:
        if not pid.isdecimal():
            continue
        process = Path("/proc") / pid
        try:
            if os.readlink(process / "exe") != executable:
                continue
            owned_ports = set()
            for descriptor in (process / "fd").iterdir():
                try:
                    target = os.readlink(descriptor)
                except OSError:
                    continue
                if target in sockets:
                    owned_ports.add(sockets[target])
        except OSError:
            continue
        if owned_ports == ports:
            return process.name
    return None


def wait_for_listener(ports, timeout=12):
    ports = {int(port) for port in ports}
    if not ports:
        raise ValueError("没有可检查的 Xray TCP 监听端口。")
    manager = service_manager()
    deadline = time.monotonic() + timeout
    previous_pid = None
    while (remaining := deadline - time.monotonic()) > 0:
        pids = managed_pids(manager, min(2, remaining))
        pid = listener_pid(ports, pids) if pids else None
        if pid and pid == previous_pid:
            return
        previous_pid = pid
        time.sleep(max(0, min(0.35, deadline - time.monotonic())))
    port_list = ", ".join(str(port) for port in sorted(ports))
    raise ValueError(f"Xray 未在规定时间内监听 TCP {port_list}。")


def save(config, original, port, progress):
    manager = service_manager()
    if manager == "openrc":
        restart = ("rc-service", "xray", "restart")
        status = ("rc-service", "xray", "status")
    else:
        restart = ("systemctl", "restart", "xray")
        status = ("systemctl", "is-active", "--quiet", "xray")

    with tempfile.TemporaryDirectory(prefix=".users-", dir=ROOT) as directory:
        candidate = Path(directory) / "config.json"
        previous = Path(directory) / "config.previous.json"
        candidate.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
        progress("正在验证配置…")
        command(str(BINARY), "run", "-test", "-c", str(candidate), timeout=15)
        state = command(*status, timeout=5, check=False, quiet=True).returncode
        stopped_states = (3, 16, 32, 64) if manager == "openrc" else (3,)
        if state != 0 and state not in stopped_states:
            raise ValueError("无法确认 Xray 的运行状态，请检查服务后再试。")
        previous.write_bytes(original)
        os.replace(previous, ROOT / previous.name)
        if state != 0:
            os.replace(candidate, CONFIG)
            return

        try:
            os.replace(candidate, CONFIG)
            progress("正在重启并检查 Xray 监听…")
            command(*restart)
            wait_for_listener([port])
        except SERVICE_ERRORS + (KeyboardInterrupt,) as original_error:
            if candidate.exists():
                raise
            try:
                previous.write_bytes(original)
                os.replace(previous, CONFIG)
                command(*restart)
                wait_for_listener([port])
            except SERVICE_ERRORS + (KeyboardInterrupt,) as rollback_error:
                raise ValueError(
                    f"应用配置失败（{original_error or '操作已中断'}）。"
                    f"回滚检查也失败（{rollback_error or '操作已中断'}）。"
                    f"上一份配置可在 {ROOT / previous.name} 找到。"
                ) from None
            raise ValueError(
                f"应用配置失败（{original_error or '操作已中断'}）。已恢复原配置和监听。"
            ) from None


def manage(action, name=None, progress=lambda message: None, expected_id=None):
    os.umask(0o077)
    read_only = action in ("list", "list-links")
    with operation_lock(shared=read_only):
        if INSTALL_TRANSACTION.exists() or INSTALL_TRANSACTION.is_symlink():
            raise ValueError("上次安装或升级尚未完成，请重新运行安装脚本以恢复。")
        if UNINSTALL_PENDING.exists() or UNINSTALL_PENDING.is_symlink():
            raise ValueError("卸载尚未完成，请先通过 xy 菜单继续卸载。")
        original = CONFIG.read_bytes()
        config = json.loads(original)
        inbounds = [item for item in config["inbounds"]
                    if item.get("protocol") == "vless"]
        if len(inbounds) != 1:
            raise ValueError("配置必须恰好包含一个 VLESS 入站。")
        clients = inbounds[0]["settings"]["clients"]
        if action == "list":
            return clients
        if action == 'list-links':
            return inbounds[0]

        matches = [client for client in clients if client.get("email") == name]
        if action == "remove":
            if len(matches) != 1:
                raise ValueError("找不到该用户名，或用户名重复。")
            if expected_id is not None and matches[0]['id'] != expected_id:
                raise ValueError('用户已变更，请重新选择。')
            if len(clients) == 1:
                raise ValueError("至少保留一名用户。")
            clients.remove(matches[0])
            result = f"已删除 {name}。"
        else:
            if matches:
                raise ValueError("该用户名已存在。")
            if action == "name-existing":
                unnamed = [client for client in clients if not client.get("email")]
                if len(unnamed) != 1:
                    raise ValueError("只有恰好一名未命名用户时才能使用此命令。")
                client = unnamed[0]
                client["email"] = name
            else:
                client = {"email": name, "id": str(uuid.uuid4()),
                          "flow": "xtls-rprx-vision"}
                clients.append(client)
            result = f'{name}\t{client["id"]}'
        save(config, original, inbounds[0]["port"], progress)
        return result

ERRORS = SERVICE_ERRORS + (KeyError, TypeError, IndexError)
NAME_HINT = "用户名须为 1–64 位字母、数字、点、下划线或连字符，首位为字母或数字。"


def color(value, code):
    if sys.stdout.isatty() and os.environ.get("TERM") != "dumb" and not os.environ.get("NO_COLOR"):
        return f"\033[{code}m{value}\033[0m"
    return value


def display_users(users):
    names = [client.get("email") or "（未命名）" for client in users]
    width = max([8, *(len(name) + (5 if name == "（未命名）" else 0) for name in names)])
    print(color(f"{'#':>3}  {'Username':<{width}}  UUID", "36"))
    for index, (name, client) in enumerate(zip(names, users), 1):
        columns = len(name) + (5 if name == "（未命名）" else 0)
        print(f"{index:>3}  {name}{' ' * (width - columns)}  {client['id']}")
    print(f"\n共 {len(users)} 位用户。")


def format_server_address(value):
    try:
        address = ip_address(value)
        if address.version == 6:
            if address.scope_id is not None:
                raise ValueError("节点地址不能使用 IPv6 区域标识。")
            return f"[{address}]"
        return str(address)
    except ValueError:
        pass
    ascii_name = value.encode("idna").decode("ascii")
    labels = ascii_name.rstrip(".").split(".")
    if (len(ascii_name) <= 253 and len(labels) >= 2
            and not all(label.isdecimal() for label in labels)
            and all(HOST_LABEL.fullmatch(label) for label in labels)):
        return ascii_name.lower().rstrip(".")
    raise ValueError("节点地址必须是域名、IPv4 或 IPv6 地址。")


def server_address():
    """Resolve the node address for a connection link, with a bounded fallback."""
    try:
        configured = (ROOT / "server-address").read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        pass
    except (OSError, UnicodeError):
        print("无法读取节点地址文件，尝试获取公网 IPv4。", file=sys.stderr)
    else:
        try:
            return format_server_address(configured)
        except ValueError:
            print("节点地址文件内容无效，尝试获取公网 IPv4。", file=sys.stderr)
    cache = ROOT / "server-ip.cache"
    current_install = None
    try:
        current_install = ROOT.stat()
        with cache.open(encoding="ascii") as source:
            age = time.time() - os.fstat(source.fileno()).st_mtime
            if 0 <= age < IP_CACHE_SECONDS:
                return str(IPv4Address(source.read().strip()))
    except (OSError, ValueError):
        pass
    deadline = time.monotonic() + 3
    for endpoint in ("https://api.ipify.org", "https://ifconfig.me/ip"):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            result = subprocess.run(
                ["curl", "-fsS4", "--connect-timeout", "1", "--max-time",
                 f"{min(1.4, remaining):.3f}", endpoint],
                capture_output=True, text=True, check=True, timeout=min(1.5, remaining),
            )
            address = str(IPv4Address(result.stdout.strip()))
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        try:
            with operation_lock(timeout=0):
                if current_install and os.path.samestat(current_install, ROOT.stat()):
                    with tempfile.TemporaryDirectory(prefix=".address-", dir=ROOT) as directory:
                        candidate = Path(directory) / cache.name
                        candidate.write_text(address + "\n", encoding="ascii")
                        candidate.chmod(0o600)
                        os.replace(candidate, cache)
        except (OSError, ValueError):
            pass
        return address
    return "YOUR_SERVER_IP"


def display_links(inbound, user_id=None):
    clients = inbound["settings"]["clients"]
    if user_id is None:
        display_users(clients)
    else:
        clients = [client for client in clients if client["id"] == user_id]
        if not clients:
            raise ValueError("该用户已不在当前配置中。")
    if not clients:
        return
    stream = inbound["streamSettings"]
    reality = stream["realitySettings"]
    try:
        key = subprocess.run(
            [str(BINARY), "x25519", "-i", reality["privateKey"]],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3,
        )
    except subprocess.TimeoutExpired:
        raise ValueError("Xray 公钥计算超时。") from None
    public_key = re.search(
        r"^(?:Password(?: \(PublicKey\))?|Public\s*Key):\s*([\w-]{43})\s*$",
        key.stdout, re.MULTILINE | re.IGNORECASE,
    )
    if key.returncode or not public_key:
        raise ValueError("无法获取 REALITY 公钥，请检查 Xray 版本及配置。")

    server = server_address()
    if server == "YOUR_SERVER_IP":
        print(color("无法检测公网 IPv4，请将链接中的 YOUR_SERVER_IP 替换为节点地址。", "33"))

    for client in clients:
        name = client.get("email") or "未命名"
        params = {
            "encryption": "none", "security": "reality",
            "sni": reality["serverNames"][0], "fp": "chrome",
            "pbk": public_key[1], "sid": reality["shortIds"][0],
            "type": stream.get("network", "tcp"),
        }
        if client.get("flow"):
            params["flow"] = client["flow"]
        print(color(f"\n{name}", "36"))
        print(f"vless://{quote(client['id'], safe='')}@{server}:{inbound['port']}"
              f"?{urlencode(params)}#{quote(name, safe='')}")


def display_added_link(user_id):
    try:
        display_links(manage("list-links"), user_id)
    except ERRORS as error:
        print(color(f"用户已添加，但未能生成链接：{error}", "33"), file=sys.stderr)


def xy_is_owned():
    if XY.is_symlink() or not XY.is_file():
        return False
    with XY.open("rb") as source:
        first = source.readline(128).rstrip(b"\r\n")
        second = source.readline(128).rstrip(b"\r\n")
        if first == b"#!/usr/bin/env python3" and second == XY_HEADER:
            return True
        if os.fstat(source.fileno()).st_size != 12651:
            return False
        source.seek(0)
        return sha256(source.read()).hexdigest() == LEGACY_XY_SHA256


def uninstall():
    manager = service_manager()
    if manager == "openrc":
        service = Path("/etc/init.d/xray")
        stop = ("rc-service", "xray", "stop")
        disable = ("rc-update", "del", "xray", "default")
    else:
        service = Path("/etc/systemd/system/xray.service")
        stop = ("systemctl", "stop", "xray.service")
        disable = ("systemctl", "disable", "xray.service")

    print(color("\n将停止 Xray、取消开机自启，并永久删除以下内容：", "33"))
    print(f"  {service}\n  {ROOT}（含程序、配置和全部用户）\n  {XY}（若由本安装器创建）\n")
    if input("输入 UNINSTALL 确认，回车取消：").strip() != "UNINSTALL":
        print("已取消卸载。")
        return False

    os.umask(0o077)
    with operation_lock():
        if INSTALL_TRANSACTION.exists() or INSTALL_TRANSACTION.is_symlink():
            raise ValueError("上次安装或升级尚未完成，请重新运行安装脚本以恢复。")
        if ROOT.is_symlink() or service.is_symlink() or UNINSTALL_PENDING.is_symlink():
            raise ValueError("安装目录、服务文件或卸载记录异常，已取消卸载。")
        pending = UNINSTALL_PENDING.is_file()
        if pending and UNINSTALL_PENDING.read_text(encoding="utf-8").strip() != OWNER:
            raise ValueError("卸载记录内容异常，已取消卸载。")
        if (ROOT.exists() or not pending) and not ROOT.is_dir():
            raise ValueError(f"安装目录异常：{ROOT}")
        if service.is_file():
            definition = service.read_text(encoding="utf-8").splitlines()
            if (f"command={BINARY}" not in definition
                    and not any(line.startswith(f"ExecStart={BINARY} run ") for line in definition)):
                raise ValueError(f"服务文件未指向 {BINARY}，已取消卸载。")
            print(color("正在停止服务并取消开机自启…", "36"), flush=True)
            command(*stop)
            if manager == "systemd" or Path("/etc/runlevels/default/xray").is_symlink():
                command(*disable)
            if not pending:
                with tempfile.TemporaryDirectory(prefix=".uninstall-", dir=UNINSTALL_PENDING.parent) as directory:
                    candidate = Path(directory) / UNINSTALL_PENDING.name
                    candidate.write_text(OWNER + "\n", encoding="utf-8")
                    os.replace(candidate, UNINSTALL_PENDING)
            service.unlink()
        elif service.exists() or not pending:
            raise ValueError(f"未找到安装器创建的服务文件：{service}")

        if manager == "systemd":
            command("systemctl", "daemon-reload")
        else:
            command("rc-update", "-u", "show", "default")
        if ROOT.exists():
            shutil.rmtree(ROOT)
        if xy_is_owned():
            XY.unlink()
        UNINSTALL_PENDING.unlink()

    print(color("\n✓ Xray 已卸载。", "32"))
    return True


def menu():
    actions = {"2": "add", "3": "name-existing", "4": "remove"}
    while True:
        try:
            print(color("\n── Xray 用户管理 ──", "36"))
            print("\n  1. 查看所有用户\n  2. 新增用户\n  3. 给原有用户命名\n  4. 删除用户\n  5. 完整卸载 Xray\n  0. 退出\n")
            choice = input("请选择 [0–5]：").strip()
            if choice == "0":
                return
            if choice == "5":
                if uninstall():
                    return
                continue
            if choice == "1":
                display_links(manage("list-links"))
                continue
            if choice not in actions:
                print(color("请输入 0–5。", "33"))
                continue

            expected_id = None
            if choice == "4":
                users = [client for client in manage("list") if client.get("email")]
                if not users:
                    print(color("没有可按名称删除的用户。", "33"))
                    continue
                display_users(users)
                selected = input("输入用户编号，回车取消：").strip()
                if not selected:
                    continue
                choices = {str(i): client for i, client in enumerate(users, 1)}
                if selected not in choices:
                    print(color("编号无效。", "33"))
                    continue
                client = choices[selected]
                name, expected_id = client["email"], client["id"]
                if input(f"确认删除 {name}？输入 y 确认，回车取消：").strip().lower() != "y":
                    continue
            else:
                while True:
                    name = input("输入用户名，回车取消：").strip()
                    if not name or NAME.fullmatch(name):
                        break
                    print(color(NAME_HINT, "33"))
                if not name:
                    continue

            result = manage(actions[choice], name,
                            lambda message: print(color(message, "36"), flush=True),
                            expected_id)
            if choice == "4":
                print(color(result, "32"))
            else:
                user, user_id = result.split("\t", 1)
                print(color(f"\n✓ 已保存用户 {user}", "32"))
                print(f"UUID  {user_id}")
                if choice == "2":
                    display_added_link(user_id)
        except (EOFError, KeyboardInterrupt):
            print()
            return
        except ERRORS as error:
            print(color(f"错误：{error}", "31"))


def main():
    parser = argparse.ArgumentParser(description="管理 Xray VLESS 用户")
    parser.add_argument("--version", action="version", version="xy 1.1")
    parser.add_argument("action", nargs="?", choices=("list", "add", "remove", "name-existing"))
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("请用 root 执行。")
    os.umask(0o077)
    if args.action is None:
        if not sys.stdin.isatty():
            parser.error("菜单需要交互终端。可指定 list、add、remove 或 name-existing。")
        menu()
        return
    if args.action == "list":
        if args.name:
            parser.error("list 不需要用户名。")
    elif not NAME.fullmatch(args.name or ""):
        parser.error(NAME_HINT)
    try:
        if args.action == "list":
            display_links(manage("list-links"))
            return
        result = manage(args.action, args.name)
        print(result)
        if args.action == "add":
            display_added_link(result.split("\t", 1)[1])
    except ERRORS as error:
        parser.exit(1, f"错误：{error}\n")


if __name__ == "__main__":
    main()
