# liuis-ray

个人 Linux 节点的初始化与终端维护工具。配置两条互补通道，自动识别公网 IPv4，生成连接信息和二维码。

适用于 Debian 12 / 13、Ubuntu 22.04 / 24.04 LTS，支持 amd64、arm64，要求 systemd。

以下命令以 root 执行。普通账户先执行 `sudo -i`；精简 Debian 的 root 环境不需要安装 sudo。

## 安装或升级

如系统没有 curl，先执行：

```bash
apt-get update && apt-get install -y ca-certificates curl
```

```bash
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.7.0/install.sh | bash'
```

普通升级保留连接凭据。两个运行组件均使用固定版本的官方发行文件，并验证 SHA-256；下载校验通过后才修改现有服务。

v0.6.2 将 Xray 固定版本从 26.10.21 回退到 26.7.28，用于客户端兼容性对照；Hysteria2 仍为 2.9.2。Reality 显式使用 `minClientVer: "1.0.0"`，避免旧内核默认的版本门槛拒绝第三方客户端，密钥及 Short ID 认证不变；已有的显式版本限制保留。已有安装运行上面的普通升级命令即可回退，保留连接凭据和证书，不要使用 `--reinstall`。v0.5.0 未固定 Xray 内核版本，因此本次不代表恢复每台服务器最初安装的精确版本。

v0.6.1 将已有 Cloudflare / Microsoft Reality 目标迁移到 Bing，保留 UUID、密钥和 Short ID。升级后请同步客户端的 SNI 为 `www.bing.com`，或重新导入生成的链接；Hysteria2 的 SNI 不变。

云平台防火墙需要放行 TCP 443 与 UDP 443。使用自定义端口时放行对应端口。已启用的 UFW 会自动添加本机规则。

## 管理菜单

```bash
liuisray
```

菜单提供连接信息、二维码、状态、日志、重启、系统网络调度设置和组件更新。

- `10`：全新重装，清理旧程序、配置和凭据，生成新链接。
- `11`：卸载清理，删除本项目程序、服务和托管文件。
- `0`：退出。

重装和卸载选择后直接执行，没有二次确认。

也可以直接运行：

```bash
liuisray show
liuisray qr all
liuisray status
liuisray logs all
liuisray restart
liuisray update
liuisray bbr
liuisray reinstall
liuisray uninstall
```

`update` 安装本版工具固定的组件版本；升级工具本身使用上方安装命令。

## 全新重装

已有旧版也可以直接执行这一行，无需先进入旧菜单：

```bash
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.7.0/install.sh | bash -s -- --reinstall'
```

先下载、校验并检查新组件，再备份旧安装，停止服务，清理本项目旧文件，最后全新安装。地址、节点名称和端口沿用已保存设置，也可通过参数修改；连接凭据、密钥和证书全部重新生成，客户端必须重新导入新链接。

清理包括本项目运行文件、配置、状态、专用服务及覆盖项、旧版模板、已知日志文件、已知数据文件和脚本产生的配置备份。不会递归删除共享目录。如果发现其他配置或额外实例共用这些程序，会停止清理，避免影响其他部署。

## 卸载

```bash
liuisray uninstall
```

旧版本尚无此命令时，也可用新脚本直接卸载：

```bash
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.7.0/install.sh | bash -s -- --uninstall'
```

与重装使用同一套清理逻辑。系统依赖、系统账户、云平台及本机防火墙规则、系统网络调度设置、公共日志和其他项目文件保留。

## 恢复备份

重装或卸载前，旧托管文件会归档到 `/var/backups/liuis-ray/时间与随机后缀/config.tar.gz`；归档失败时停止。此恢复归档在清理后保留，包含旧连接凭据，仅供 root 访问。

查看归档内容（替换实际路径）：

```bash
tar -tzf /var/backups/liuis-ray/实际备份目录/config.tar.gz
```

## 自定义与检查

下载脚本后运行 `bash install.sh --help` 查看完整参数。例如：

```bash
bash install.sh --reinstall --name node-1 --port 443 --hy2-port 443
```

非本项目管理的现有配置不会自动覆盖；审查、备份后可显式使用 `--force` 接管安装。

服务以独立低权限账户运行，通过服务权限绑定所需端口。安装和重启后会检查短期运行状态及重启次数，避免把刚启动又退出的进程报告为成功。

项目不开放网页控制台或公开管理入口。实现和固定版本见 [`install.sh`](./install.sh)。请在自己拥有或获准管理的设备上使用。

## 可选：VLESS + XHTTP + REALITY

v0.7.0 新增菜单 `12` 和 `liuisray xhttp`，独立安装这条通道。每次安装或更新查询 Xray 官方最新正式版本，并验证官方 SHA-256。使用独立的程序、凭据、配置和 systemd 服务，不修改或重启原有 VLESS/TCP、Hysteria2，也不更改它们的固定版本。

已有旧版安装时，使用下面的命令，只添加新通道，无需重新运行原安装器：

```bash
bash -c 'set -e; f=$(mktemp); trap '\''rm -f -- "$f"'\'' EXIT; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.7.0/install-xhttp.sh -o "$f"; bash "$f" install'
```

首次安装默认随机选择空闲 TCP 端口，更新时保留原端口和凭据。请在云平台防火墙放行输出的 TCP 端口；已启用的 UFW 会自动添加放行规则。新通道默认 SNI 为 `www.cloudflare.com`，原通道的目标不变。

```bash
liuisray-xhttp install --port 23456
liuisray-xhttp install --random-port
liuisray-xhttp install
liuisray-xhttp show
liuisray-xhttp status
liuisray-xhttp logs
liuisray-xhttp restart
```

`--port` 指定新端口，`--random-port` 重新随机选择端口，不带参数则保留端口并更新到最新版。改端口后需同步客户端链接和云平台防火墙。可用 `--address` 指定公网 IP/域名，`--server-name` 指定新通道的 SNI。

配置在 `/etc/liuis-ray-xhttp/`，内核在 `/usr/local/lib/liuis-ray-xhttp/`，服务为 `liuis-ray-xhttp.service`。安装前备份到 `/var/backups/liuis-ray-xhttp.*`，服务更新失败时恢复该通道的文件。原菜单的更新、重启和卸载仍只管理原有两条通道。

生成的链接使用 XHTTP，不添加 Vision flow。需要支持 XHTTP 的客户端；普通 Reality 能用不代表支持 XHTTP。请通过 `liuisray-xhttp show` 获取新通道链接，不要复用原通道凭据。

## License

MIT
