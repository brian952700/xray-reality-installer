# Xray REALITY 安装器

支持 Alpine Linux（OpenRC）和 Debian 12 及以上（systemd）。需 root 权限、可用软件源与 GitHub 网络连接。未运行对应服务管理器的容器不适用。

## 一键下载安装（无需 Token）

在服务器 root 终端执行。首次安装时，按提示输入 10000–65535 的端口并按回车（必填，无默认值）。已有安装时，同一条命令用于升级：

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

## 安装界面

安装过程分步显示进度。命令失败时会显示相应日志。通过 `NO_COLOR=1` 可禁用颜色。

## 升级与用户管理

安装器校验 Xray 和用户管理脚本的 SHA-256。依赖齐全时会跳过软件包安装。

升级保留 `/opt/xray/config.json` 中的端口、凭据和用户。升级失败时，安装器会尝试恢复上一次的程序、配置和服务状态，并显示恢复结果。请先阅读失败原因和回滚结果，再重试同一条命令。

以 root 运行 `xy` 打开菜单，可查看各用户的 VLESS 链接、新增或删除用户，以及卸载 Xray。也可以运行 `xy list` 或 `xy add 用户名`（用户名使用英文字母、数字、点、下划线或连字符）。

如果有固定域名或公网 IP，可以把地址写入 `/opt/xray/server-address`。`xy` 优先使用这个地址。未设置时复用近期探测到的公网 IPv4，探测失败时可手动替换链接中的 `YOUR_SERVER_IP`。

```sh
printf '%s\n' 'proxy.example.com' > /opt/xray/server-address
```

## 按用户配置出口

运行 `xy`，选择 `5. 配置用户出口`。菜单先列出用户及当前出口，输入需要走新出口的用户编号（例如 `1 3` 或 `1,3`）。编号留空直接回车会选择全部当前用户，确认页会明确显示人数。接着粘贴一条 `vless://` 或 `ss://` 链接，检查出口地址与用户列表，输入 `y` 后应用。链接留空或在确认时直接回车可取消。

配置会写入 `/opt/xray/config.json` 的 `outbounds` 和按用户匹配的路由规则。未选中的用户保留现有规则。未命名的选中用户会自动获得唯一用户名，原 UUID 和客户端链接继续使用。再次选择部分用户配置新出口时，其他用户继续使用各自原来的出口。新增用户沿用原配置的默认路由。

VLESS 支持 UUID、TCP/RAW、WebSocket、gRPC、HTTPUpgrade、XHTTP，以及无 TLS、TLS 和 REALITY。SS 支持常见 AEAD/2022 加密与标准、旧式 Base64 链接。带 SS 插件、未知参数或不支持的传输方式会提示错误。脚本在写入前调用当前 Xray 校验配置，应用失败时尝试恢复原配置与监听。服务原本停止时只保存配置。

出口可达性取决于提供的节点。请在应用后使用选中用户的客户端实际连接确认。`6. 完整卸载 Xray` 位于退出之前。

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

请在主机防火墙与云安全组放行你选择的 TCP 端口，脚本不修改防火墙。需有可访问的公网地址；NAT 主机还需端口转发。公网 IPv4 查询失败时，手动替换输出链接中的 YOUR_SERVER_IP。

配置位于 `/opt/xray/config.json`。使用本脚本初始化的配置文件权限为 600。
