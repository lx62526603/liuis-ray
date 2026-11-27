#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./install-xhttp.sh
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
bash -n install-xhttp.sh
bash install-xhttp.sh --help | grep -q -- --port
for p in 1 443 12345 65535; do validate_port "$p"; done
for p in 0 -1 65536 12abc 01 ''; do
  if validate_port "$p"; then die "Accepted invalid port: $p"; fi
done
port="$(choose_port 0)"
validate_port "$port"
printf 'PASS: explicit port validation and random available port\n'
python3 - "$TEST_DIR/release.json" <<'PY'
import json,sys
json.dump(dict(tag_name='v26.11.9',draft=False,prerelease=False,assets=[dict(name='Xray-linux-64.zip',digest='sha256:'+'a'*64,browser_download_url='https://github.com/XTLS/Xray-core/releases/download/v26.11.9/Xray-linux-64.zip')]),open(sys.argv[1],'w'))
PY
release_metadata "$TEST_DIR/release.json" Xray-linux-64.zip >"$TEST_DIR/release.txt"
grep -q '^v26.11.9$' "$TEST_DIR/release.txt"
python3 - "$TEST_DIR/release.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s['assets'][0]['digest']=''; json.dump(s,open(p,'w'))
PY
if release_metadata "$TEST_DIR/release.json" Xray-linux-64.zip >/dev/null 2>&1; then die 'Missing checksum accepted'; fi
printf 'PASS: latest release parsing and missing-checksum rejection\n'
render_config - "$TEST_DIR/state.json" "$TEST_DIR/config.json" "$port" 203.0.113.10 '' v26.11.9 12345678-1234-1234-1234-123456789abc "$(printf 'a%.0s' {1..43})" "$(printf 'b%.0s' {1..43})" 0123456789abcdef
render_config "$TEST_DIR/state.json" "$TEST_DIR/state2.json" "$TEST_DIR/config2.json" 23456 '' '' v26.11.10 '' '' '' ''
python3 - "$TEST_DIR" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]); s=json.load(open(p/'state.json')); t=json.load(open(p/'state2.json')); c=json.load(open(p/'config2.json'))
assert all(s[k]==t[k] for k in ['uuid','private_key','public_key','short_id','path','sni','address'])
assert t['port']==23456 and t['version']=='v26.11.10'
i=c['inbounds'][0]; assert i['port']==23456
assert i['streamSettings']['network']=='xhttp' and i['streamSettings']['security']=='reality'
assert i['streamSettings']['xhttpSettings']['path']==s['path']
assert 'flow' not in i['settings']['clients'][0]
assert s['sni']=='www.cloudflare.com'
PY
CONFIG_DIR="$TEST_DIR"
link="$(show_link | tail -1)"
python3 - "$link" <<'PY'
import sys,urllib.parse
u=urllib.parse.urlsplit(sys.argv[1]); q=urllib.parse.parse_qs(u.query)
assert q['type']==['xhttp'] and q['mode']==['auto'] and q['security']==['reality']
assert q['path'][0].startswith('/') and 'flow' not in q
PY
printf 'PASS: isolated XHTTP config, port changes, stable credentials and native link\n'
