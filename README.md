# Xray REALITY 固定配置安装器

支持 Alpine Linux（OpenRC）和 Debian 12 及以上（systemd）。需 root 权限、可用软件源与 GitHub 网络连接。未运行对应服务管理器的容器不适用。

## 固定配置

- 目标域名：`www.apple.com`（REALITY 目标端口 443）
- 监听端口：`38503/TCP`
- 所有部署共用 UUID、密钥对和 ShortID；生成的连接链接仅服务器 IP 不同。
- 脚本会自动安装 curl、unzip、CA 证书等依赖，验证配置并启动服务、设置开机自启。

## 一键下载安装（私有仓库）

在服务器 root 终端执行下面整条命令。命令会先补齐 curl 和 CA 证书，然后下载并执行脚本。

提示 `Enter host password for user 'brian952700':` 时，输入有本仓库读取权限的 GitHub Personal Access Token（不是 GitHub 登录密码）；输入不会回显。不要将令牌写进命令或脚本。

```sh
sh -c 'set -e; [ "$(id -u)" -eq 0 ] || { echo "请使用 root 执行"; exit 1; }; . /etc/os-release; case "$ID" in debian) apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates;; alpine) apk add --no-cache curl ca-certificates;; *) echo "不支持此系统"; exit 1;; esac; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; curl -fL --user brian952700 -H "Accept: application/vnd.github.raw+json" "https://api.github.com/repos/brian952700/xray-reality-installer/contents/install-fixed.sh?ref=main" -o "$f"; sh "$f"'
```

[下载脚本（需登录 GitHub）](https://github.com/brian952700/xray-reality-installer/blob/main/install-fixed.sh)

也可从仓库下载脚本、上传服务器后执行：

```sh
sh install-fixed.sh
```

## 服务管理

Debian：

```sh
systemctl status xray
systemctl restart xray
systemctl stop xray
journalctl -u xray -n 50 --no-pager
```

Alpine：

```sh
rc-service xray status
rc-service xray restart
rc-service xray stop
```

## 部署说明

请在主机防火墙与云安全组放行 TCP 38503，脚本不修改防火墙。需有可访问的公网地址；NAT 主机还需端口转发。公网 IPv4 查询失败时，手动替换输出链接中的 YOUR_SERVER_IP。

配置位于 `/opt/xray/config.json`，权限为 600。重复执行会更新 Xray、覆盖该配置并重启服务，固定凭据保持一致。脚本含固定私钥，应保持仓库私有。

已检查配置 JSON 和密钥匹配；尚未在 Linux 实机完成安装和连通性测试。
