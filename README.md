# liuis-ray

A small, auditable installer for a personal encrypted tunnel:

- VLESS + TCP + REALITY + Vision
- No public administration panel
- Share URI and terminal QR code
- Optional `fq` + BBR configuration
- Core installation delegated to the official XTLS installer

The current release supports clean Debian 12+ and Ubuntu 22.04+ VPS instances
using systemd.

## Security model

This project deliberately does **not** expose a web administration panel.
The server configuration is readable only by root and the core service
group. The official XTLS installer is pinned to a reviewed commit and its
installer SHA-256 is verified before execution. That upstream installer then
verifies the downloaded core release archive.

The generated `vless://` URI is a bearer secret: anyone who obtains it receives
the node credential. Do not publish it, commit it, or paste it into public
configuration-conversion websites.

## Recommended installation

One-line installation with automatic public IPv4 detection:

```bash
sudo bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.3.0/install.sh | bash'
```

The installer tries three IPv4 lookup services in sequence. You do not normally
need to provide `--address`. To review the script before execution:

```bash
curl -fL \
  https://raw.githubusercontent.com/lx62526603/liuis-ray/v0.3.0/install.sh \
  -o liuis-ray-install.sh
less liuis-ray-install.sh
sudo bash liuis-ray-install.sh
```

The installer uses TCP port 443 by default and enables `fq` + BBR:

```bash
sudo bash install.sh
```

Useful options:

```text
--port PORT
--server-name DOMAIN
--target-port PORT
--address IPV4_OR_DOMAIN
--name ASCII_NODE_NAME
--no-bbr
--force
```

The default REALITY target is `www.microsoft.com:443`. The installer verifies
that the selected target is reachable from the VPS with TLS 1.3 before writing
the configuration. You can select another stable, legitimate TLS 1.3 site:

```bash
sudo bash install.sh \
  --server-name www.example.com \
  --address 203.0.113.10 \
  --name tokyo-1
```

Do not use an arbitrary target merely because it appears in an online tutorial.
The target should be stable and reachable from the VPS. Avoid Apple/iCloud
targets, for which recent upstream versions emit warnings.

## Management commands

```bash
sudo liuis-ray show
sudo liuis-ray qr
sudo liuis-ray status
sudo liuis-ray logs
sudo liuis-ray restart
sudo liuis-ray update
sudo liuis-ray bbr
```

`liuis-ray update` uses the same pinned official XTLS installer. The installer
queries the latest stable core release and verifies the archive digest
before replacing the binary.

## Firewall

If UFW is already active, the installer opens the selected tunnel TCP port. It
does not enable UFW automatically, because doing so incorrectly can lock you
out of SSH.

For a new VPS, a typical setup is:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 443/tcp
sudo ufw enable
```

Your cloud/VPS provider may have a separate security group or network firewall.
Open the same ports there.

## Files

```text
/usr/local/etc/xray/config.json
/etc/liuis-ray/state.env
/usr/local/sbin/liuis-ray
/etc/systemd/system/xray.service.d/20-liuis-ray-hardening.conf
```

The state file and server configuration contain private credentials. Back them
up securely and never commit them to Git.

## Limitations

- IPv4/domain client addresses only in this initial release
- One client identity
- One VLESS REALITY inbound
- The script does not alter a provider security group
- BBR requires kernel support; some container-based VPS products do not allow it

Use this only where permitted by local law and the VPS provider's terms.
