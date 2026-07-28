# liuis-ray

面向个人 VPS 的双协议一键部署脚本：

- VLESS + REALITY + RAW + XTLS Vision（TCP）
- Hysteria2 + Salamander（UDP）
- 自动检测 VPS 公网 IPv4
- 自动生成客户端链接和终端二维码
- `liuisray` 中文交互式管理面板
- 一键启用并检查 fq + BBR
- 支持从旧版 liuis-ray 原地升级并保留 VLESS 凭据

不安装 Web 面板、不提供公网订阅接口，也不会开放额外的管理端口。

## 系统要求

- Debian 12 或更新版本
- Ubuntu 22.04 或更新的 LTS 版本
- systemd
- amd64 或 arm64
- root 或 sudo 权限

客户端建议使用最新版：

- Clash Verge Rev（Mihomo）
- Shadowrocket

## 一行安装或升级

```bash
sudo bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.4.0/install.sh | bash'
```

第一次安装会生成新的 VLESS 和 Hysteria2 凭据。再次运行同一命令会识别现有的托管安装、保留 VLESS 凭据并补齐或更新 Hysteria2。

如果服务器上已有并非 liuis-ray 管理的 Xray 或 Hysteria2 配置，脚本会停止。确认备份后才可以使用：

```bash
sudo bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.4.0/install.sh | bash -s -- --force'
```

## 云平台防火墙

默认必须同时放行：

| 协议 | 端口 | 用途 |
|---|---:|---|
| TCP | 443 | VLESS + REALITY |
| UDP | 443 | Hysteria2 |

脚本会在 UFW 已启用时自动添加规则，但不能代替 Google Cloud、AWS、Azure 等云平台的安全组或 VPC 防火墙规则。

## 管理面板

安装完成后输入：

```bash
liuisray
```

普通用户执行时会自动调用 `sudo`。旧命令 `liuis-ray` 仍然可用。

菜单提供：

1. 查看两个客户端链接
2. 显示 VLESS 二维码
3. 显示 Hysteria2 二维码
4. 查看服务、监听端口和 BBR 状态
5. 重启服务
6. 查看 Xray 日志
7. 查看 Hysteria2 日志
8. 启用 fq + BBR
9. 更新代理核心

也可以直接运行非交互命令：

```bash
sudo liuisray show
sudo liuisray qr vless
sudo liuisray qr hy2
sudo liuisray status
sudo liuisray restart
sudo liuisray logs xray
sudo liuisray logs hy2
sudo liuisray update
sudo liuisray bbr
```

## 自定义安装

```bash
sudo bash install.sh \
  --address 203.0.113.10 \
  --name tokyo-1 \
  --port 443 \
  --hy2-port 443 \
  --server-name www.microsoft.com
```

可用参数：

```text
--port PORT
--hy2-port PORT
--server-name DOMAIN
--target-port PORT
--address HOST
--name NAME
--no-bbr
--force
```

现有安装升级时可以修改节点名称、公网地址和 Hysteria2 UDP 端口。为了避免状态与真实 Xray 配置不一致，升级模式不会直接修改已经部署的 Xray 端口或 REALITY 目标。

## 安全设计

- Xray 通过固定提交的官方安装脚本安装，并校验脚本 SHA-256。
- Hysteria2 固定为经过校验的官方版本，下载后校验 SHA-256。
- Hysteria2 使用独立随机认证密码、Salamander 混淆密码和自签证书。
- 客户端链接包含证书 SHA-256 固定值，避免仅使用 `insecure` 带来的中间人风险。
- 状态文件为 `/etc/liuis-ray/state.env`，权限为 `0600`。
- Xray 配置采用当前字段名 `raw` 和 `target`。
- 两个 systemd 服务均设置自动故障重启和基础沙箱限制。
- 不开启 Web 管理面板、HTTPS 订阅或流量统计 API。

## 常见检查

```bash
sudo liuisray status
sudo systemctl status xray
sudo systemctl status hysteria-server
sudo ss -lntup | grep ':443'
```

如果 VLESS 可用但 Hysteria2 超时，优先检查云平台是否放行 **UDP 443**。如果当前网络完全封锁 UDP，继续使用 VLESS 节点即可。

## 卸载

项目暂不提供自动卸载，避免误删服务器上已有配置。相关文件主要位于：

```text
/usr/local/bin/xray
/usr/local/bin/hysteria
/usr/local/sbin/liuisray
/usr/local/sbin/liuis-ray
/usr/local/etc/xray/
/etc/hysteria/
/etc/liuis-ray/
/etc/systemd/system/xray.service.d/
/etc/systemd/system/hysteria-server.service
```

删除前请先备份并确认这些文件没有被其他服务共用。

## 上游项目

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
- [apernet/hysteria](https://github.com/apernet/hysteria)

## License

MIT
