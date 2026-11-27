#!/usr/bin/env bash
# Run only isolated high-port processes, never install a service.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./install-xhttp.sh
CORE="$(realpath -- "${1:?Usage: bash tests/xhttp-smoke.sh /path/to/xray}")"
TEST_DIR="$(mktemp -d "$PWD/.xhttp-test.XXXXXX")"
server_pid=''; client_pid=''; http_pid=''
cleanup() {
  local pid resolved
  for pid in "$server_pid" "$client_pid" "$http_pid"; do [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; done
  resolved="$(realpath -m -- "$TEST_DIR")"
  case "$resolved" in "$PWD"/.xhttp-test.*) rm -rf -- "$resolved" ;; esac
}
trap cleanup EXIT
uuid="$("$CORE" uuid)"
"$CORE" x25519 >"$TEST_DIR/keys"
private="$(awk -F': ' '/^PrivateKey:/ {print $2}' "$TEST_DIR/keys")"
public="$(awk -F': ' '/^(Password|PublicKey)( \(PublicKey\))?:/ {print $2; exit}' "$TEST_DIR/keys")"
server_port="$(choose_port 0)"; client_port="$(choose_port 0)"; http_port="$(choose_port 0)"
render_config - "$TEST_DIR/state.json" "$TEST_DIR/server.json" "$server_port" 127.0.0.1 www.cloudflare.com test "$uuid" "$private" "$public" 0123456789abcdef
python3 - "$TEST_DIR" "$client_port" "$http_port" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); s=json.load(open(p/'state.json')); server=json.load(open(p/'server.json'))
server['outbounds'][0]['settings']={'finalRules':[{'action':'allow','network':'tcp','ip':['127.0.0.1/32'],'port':int(sys.argv[3])}]}
json.dump(server,open(p/'server.json','w'))
client={'log':{'loglevel':'info'},'inbounds':[{'listen':'127.0.0.1','port':int(sys.argv[2]),'protocol':'socks','settings':{'auth':'noauth'}}],'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':'127.0.0.1','port':s['port'],'users':[{'id':s['uuid'],'encryption':'none'}]}]},'streamSettings':{'network':'xhttp','security':'reality','xhttpSettings':{'path':s['path'],'mode':'auto'},'realitySettings':{'serverName':s['sni'],'fingerprint':'chrome','publicKey':s['public_key'],'shortId':s['short_id']}}}]}
json.dump(client,open(p/'client.json','w'))
PY
"$CORE" run -test -config "$TEST_DIR/server.json"
"$CORE" run -test -config "$TEST_DIR/client.json"
python3 - "$http_port" <<'PY' >"$TEST_DIR/http.log" 2>&1 &
import http.server,sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'xhttp-smoke-ok')
http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),Handler).serve_forever()
PY
http_pid=$!
"$CORE" run -config "$TEST_DIR/server.json" >"$TEST_DIR/server.log" 2>&1 &
server_pid=$!
"$CORE" run -config "$TEST_DIR/client.json" >"$TEST_DIR/client.log" 2>&1 &
client_pid=$!
sleep 2
if ! curl -fsS --proxy "socks5h://127.0.0.1:$client_port" --noproxy '' --connect-timeout 20 --max-time 45 "http://127.0.0.1:$http_port/" -o "$TEST_DIR/response"; then
  cat "$TEST_DIR/server.log" "$TEST_DIR/client.log" >&2
  exit 1
fi
grep -q '^xhttp-smoke-ok$' "$TEST_DIR/response"
printf 'PASS: actual latest core XHTTP + REALITY handshake and HTTP payload\n'
