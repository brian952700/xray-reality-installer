#!/usr/bin/env python3
"""Manage named users in an installed Xray VLESS inbound."""
import argparse
import fcntl
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

ROOT = Path("/opt/xray")
CONFIG = ROOT / "config.json"
BINARY = ROOT / "xray"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")


def command(*args):
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL)


def save(config, original, progress):
    if Path("/run/openrc").is_dir():
        restart = ("rc-service", "xray", "restart")
        status = ("rc-service", "xray", "status")
    elif Path("/run/systemd/system").is_dir():
        restart = ("systemctl", "restart", "xray")
        status = ("systemctl", "is-active", "--quiet", "xray")
    else:
        raise ValueError("未找到 OpenRC 或 systemd。")

    with tempfile.TemporaryDirectory(prefix=".users-", dir=ROOT) as directory:
        candidate = Path(directory) / "config.json"
        backup = Path(directory) / "original.json"
        os.umask(0o077)
        candidate.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
        progress("正在验证配置…")
        command(str(BINARY), "run", "-test", "-c", str(candidate))
        backup.write_bytes(original)
        os.replace(candidate, CONFIG)
        try:
            progress("正在重启 Xray…")
            command(*restart)
            time.sleep(2)
            command(*status)
        except (OSError, subprocess.CalledProcessError, KeyboardInterrupt):
            os.replace(backup, CONFIG)
            print("新配置启动失败，已恢复原配置。", flush=True)
            command(*restart)
            raise


def manage(action, name=None, progress=lambda message: None, expected_id=None):
    os.umask(0o077)
    with (ROOT / ".users.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        original = CONFIG.read_bytes()
        config = json.loads(original)
        inbounds = [item for item in config["inbounds"]
                    if item.get("protocol") == "vless"]
        if len(inbounds) != 1:
            raise ValueError("配置必须恰好包含一个 VLESS 入站。")
        clients = inbounds[0]["settings"]["clients"]
        if action == "list":
            return clients

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
        save(config, original, progress)
        return result

ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError)
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


def uninstall():
    if Path("/run/openrc").is_dir():
        service = Path("/etc/init.d/xray")
        stop = ("rc-service", "xray", "stop")
        disable = ("rc-update", "del", "xray", "default")
    elif Path("/run/systemd/system").is_dir():
        service = Path("/etc/systemd/system/xray.service")
        stop = ("systemctl", "stop", "xray.service")
        disable = ("systemctl", "disable", "xray.service")
    else:
        raise ValueError("未找到 OpenRC 或 systemd。")

    if service.is_symlink() or not service.is_file():
        raise ValueError(f"未找到安装器创建的服务文件：{service}")
    if str(BINARY) not in service.read_text(encoding="utf-8"):
        raise ValueError(f"服务文件未指向 {BINARY}，已取消卸载。")
    if ROOT.is_symlink() or not ROOT.is_dir():
        raise ValueError(f"安装目录异常：{ROOT}")

    print(color("\n将停止 Xray、取消开机自启，并永久删除以下内容：", "33"))
    print(f"  {service}\n  {ROOT}（含程序、配置和全部用户）\n")
    if input("输入 UNINSTALL 确认，回车取消：").strip() != "UNINSTALL":
        print("已取消卸载。")
        return False

    os.umask(0o077)
    with (ROOT / ".users.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        print(color("正在停止服务并取消开机自启…", "36"), flush=True)
        command(*stop)
        if disable[0] == "systemctl" or Path("/etc/runlevels/default/xray").is_symlink():
            command(*disable)
        service.unlink()
        if disable[0] == "systemctl":
            command("systemctl", "daemon-reload")
        shutil.rmtree(ROOT)

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
                display_users(manage("list"))
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
        except (EOFError, KeyboardInterrupt):
            print()
            return
        except ERRORS as error:
            print(color(f"错误：{error}", "31"))


def main():
    parser = argparse.ArgumentParser(description="管理 Xray VLESS 用户")
    parser.add_argument("action", nargs="?", choices=("list", "add", "remove", "name-existing"))
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("请用 root 执行。")
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
        result = manage(args.action, args.name)
        if args.action == "list":
            for client in result:
                print(f'{client.get("email") or "（未命名）"}\t{client["id"]}')
        else:
            print(result)
    except ERRORS as error:
        parser.exit(1, f"错误：{error}\n")


if __name__ == "__main__":
    main()
