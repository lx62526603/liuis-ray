# liuis-ray

一个面向个人 Linux 节点的轻量初始化与维护脚本。

它会配置两套互补的网络传输服务，自动生成连接信息，并提供终端管理菜单。项目不安装网页控制台，不开放额外的远程管理接口。

请仅在自己拥有或获准管理的服务器上使用，并遵守所在地法律及服务商条款。

## 环境

- Debian 12 / 13
- Ubuntu 22.04 / 24.04 LTS
- systemd
- amd64 或 arm64
- root 或 sudo 权限

## Debian

先确认系统版本：

```bash
cat /etc/os-release
```

Debian 12 或 13 可以直接安装。脚本会通过 `apt` 自动补齐所需组件，无需预先配置运行环境。

如系统是精简镜像且没有 `curl`，先执行：

```bash
sudo apt update
sudo apt install -y ca-certificates curl
```

## 安装或升级

```bash
sudo bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.5.0/install.sh | bash'
```

再次运行同一命令会识别已有的托管安装，保留现有连接凭据并完成必要迁移。

如果服务器上已经存在同名但并非本项目管理的配置，脚本会停止，不会直接覆盖。请先自行检查和备份；确认需要替换时再查看：

```bash
bash install.sh --help
```

## 端口

默认需要在云平台安全组或 VPC 防火墙放行：

| 类型 | 端口 | 说明 |
|---|---:|---|
| TCP | 443 | 通道 A |
| UDP | 443 | 通道 B |

如果 UFW 已启用，脚本会添加本机规则；Google Cloud、AWS、Azure 等平台侧规则仍需自行设置。

## 管理

安装完成后输入：

```bash
liuisray
```

普通用户运行时会自动请求 sudo 权限。旧命令 `liuis-ray` 仍可使用。

菜单可以：

1. 查看连接信息
2. 显示终端二维码
3. 查看服务与端口状态
4. 重启服务
5. 查看近期日志
6. 检查系统网络调度设置
7. 更新运行组件
8. 重新安装（保留连接凭据，先备份）
9. 卸载（先备份）

常用非交互命令：

```bash
sudo liuisray show
sudo liuisray qr all
sudo liuisray status
sudo liuisray restart
sudo liuisray logs all
sudo liuisray update
sudo liuisray bbr
sudo liuisray reinstall
sudo liuisray uninstall
```

## 自定义

下载脚本后查看完整参数：

```bash
bash install.sh --help
```

常见示例：

```bash
sudo bash install.sh \
  --address 203.0.113.10 \
  --name node-1 \
  --port 443 \
  --hy2-port 443
```

## 状态检查

```bash
sudo liuisray status
sudo liuisray logs all
sudo ss -lntup | grep ':443'
```

如果 TCP 通道正常、UDP 通道超时，优先检查云平台是否放行 UDP 443，以及当前接入网络是否允许 UDP。

## 安全与维护

- 下载的上游安装文件和运行文件均进行 SHA-256 校验。
- 服务使用独立的低权限系统账户运行。
- 本地状态文件位于 `/etc/liuis-ray/state.env`，权限为 `0600`。
- systemd 服务设置了故障重启和基础沙箱限制。
- 不启用网页控制台、公开订阅入口或流量统计接口。
- 升级会保留托管凭据，并对已知的不兼容旧配置进行迁移。

具体实现、固定版本及校验值均可在 [`install.sh`](./install.sh) 中审计。

## 重新安装与卸载

已有安装先运行上方安装命令，更新管理菜单。在 `liuisray` 中选择 `10` 重新安装，选择 `11` 卸载；也可直接运行：

```bash
sudo liuisray reinstall
sudo liuisray uninstall
```

两项操作都需要输入提示中的确认词。自动化执行时可添加 `--yes`。

重新安装会从当前管理工具对应的固定版本下载脚本，重新安装运行组件并重建本项目配置，覆盖手动调整。它保留地址、端口、连接凭据和证书；关键凭据或证书缺失时会停止，避免悄悄改变已有连接链接。

卸载会停止并禁用本项目服务，删除托管配置、服务文件和管理命令。其他配置文件、旧备份、共享运行文件、系统账户、系统依赖、防火墙规则和系统网络调度设置会保留。再次安装会生成新的连接凭据，客户端需要重新导入。

两项操作都会先将配置和管理文件备份到 `/var/backups/liuis-ray/<时间与随机后缀>/config.tar.gz`，备份失败时停止。备份含连接凭据，仅供 root 访问；卸载后备份仍保留。可先用下面的命令查看内容（替换实际路径）：

```bash
sudo tar -tzf /var/backups/liuis-ray/实际备份目录/config.tar.gz
```

## License

MIT
