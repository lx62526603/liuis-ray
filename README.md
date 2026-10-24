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
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.6.0/install.sh | bash'
```

普通升级保留连接凭据。两个运行组件均使用固定版本的官方发行文件，并验证 SHA-256；下载校验通过后才修改现有服务。

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
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.6.0/install.sh | bash -s -- --reinstall'
```

先下载、校验并检查新组件，再备份旧安装，停止服务，清理本项目旧文件，最后全新安装。地址、节点名称和端口沿用已保存设置，也可通过参数修改；连接凭据、密钥和证书全部重新生成，客户端必须重新导入新链接。

清理包括本项目运行文件、配置、状态、专用服务及覆盖项、旧版模板、已知日志文件、已知数据文件和脚本产生的配置备份。不会递归删除共享目录。如果发现其他配置或额外实例共用这些程序，会停止清理，避免影响其他部署。

## 卸载

```bash
liuisray uninstall
```

旧版本尚无此命令时，也可用新脚本直接卸载：

```bash
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.6.0/install.sh | bash -s -- --uninstall'
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

## License

MIT
