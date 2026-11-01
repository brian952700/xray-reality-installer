# Xray REALITY 固定配置安装器

支持 Alpine Linux（OpenRC）和 Debian 12 及以上（systemd）。需 root 权限、可用软件源与 GitHub 网络连接。未运行对应服务管理器的容器不适用。

## 固定配置

- 目标域名：`www.apple.com`（REALITY 目标端口 443）
- 监听端口：安装时交互输入，回车默认 `38503/TCP`；范围为 1–65535。无交互终端时使用默认端口。
- 所有部署共用 UUID、密钥对和 ShortID；选择相同端口时，生成的连接链接仅服务器 IP 不同；选择不同端口时，链接端口也会相应变化。
- 脚本会自动安装 curl、unzip、CA 证书等依赖，验证配置并启动服务、设置开机自启。

## 一键下载安装（无需 Token）

在服务器 root 终端执行，按提示输入端口（直接回车使用 38503）：

```sh
curl -fsSL https://raw.githubusercontent.com/brian952700/xray-reality-installer/main/install-fixed.sh | sh
```

如果提示 `curl: command not found`，请先自行安装 curl 和 CA 证书，再重新执行上面的命令。脚本下载后会自动安装其余所需依赖。

Debian：

```sh
apt-get update && apt-get install -y curl ca-certificates
```

Alpine：

```sh
apk add --no-cache curl ca-certificates
```

[直接下载脚本](https://raw.githubusercontent.com/brian952700/xray-reality-installer/main/install-fixed.sh)

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

请在主机防火墙与云安全组放行你选择的 TCP 端口（默认 38503），脚本不修改防火墙。需有可访问的公网地址；NAT 主机还需端口转发。公网 IPv4 查询失败时，手动替换输出链接中的 YOUR_SERVER_IP。

配置位于 `/opt/xray/config.json`，权限为 600。重复执行会更新 Xray、覆盖该配置并重启服务，固定凭据保持一致。仓库按所有者要求公开，并保留固定凭据；知道服务器地址的人可能使用同一凭据连接节点。

已检查配置 JSON 和密钥匹配；尚未在 Linux 实机完成安装和连通性测试。
