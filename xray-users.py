#!/usr/bin/env python3
"""Manage named users in an installed Xray VLESS inbound."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid

ROOT = Path("/opt/xray")
CONFIG = ROOT / "config.json"
BINARY = ROOT / "xray"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}")


def command(*args):
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL)


def save(config, original):
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
        command(str(BINARY), "run", "-test", "-c", str(candidate))
        backup.write_bytes(original)
        os.replace(candidate, CONFIG)
        try:
            command(*restart)
            time.sleep(2)
            command(*status)
        except (OSError, subprocess.CalledProcessError):
            os.replace(backup, CONFIG)
            print("新配置启动失败，已恢复原配置。", flush=True)
            command(*restart)
            raise


def main():
    parser = argparse.ArgumentParser(description="管理 Xray VLESS 用户")
    parser.add_argument("action", choices=("list", "add", "remove", "name-existing"))
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    if args.action == "list":
        if args.name:
            parser.error("list 不需要用户名。")
    elif not NAME.fullmatch(args.name or ""):
        parser.error("用户名须为 1–64 位字母、数字、点、下划线或连字符，首位为字母或数字。")
    if os.geteuid() != 0:
        parser.error("请用 root 执行。")

    try:
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
            if args.action == "list":
                for client in clients:
                    print(f'{client.get("email") or "（未命名）"}\t{client["id"]}')
                return

            matches = [client for client in clients if client.get("email") == args.name]
            if args.action == "remove":
                if len(matches) != 1:
                    raise ValueError("找不到该用户名，或用户名重复。")
                if len(clients) == 1:
                    raise ValueError("至少保留一名用户。")
                clients.remove(matches[0])
                result = f"已删除 {args.name}。"
            else:
                if matches:
                    raise ValueError("该用户名已存在。")
                if args.action == "name-existing":
                    unnamed = [client for client in clients if not client.get("email")]
                    if len(unnamed) != 1:
                        raise ValueError("只有恰好一名未命名用户时才能使用此命令。")
                    client = unnamed[0]
                    client["email"] = args.name
                else:
                    client = {"email": args.name, "id": str(uuid.uuid4()),
                              "flow": "xtls-rprx-vision"}
                    clients.append(client)
                result = f'{args.name}\t{client["id"]}'
            save(config, original)
            print(result)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"错误：{error}\n")


if __name__ == "__main__":
    main()
