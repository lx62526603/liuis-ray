#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source <(sed '/^while (( "\$#" )); do/,$d' install.sh)
[[ "$REALITY_SERVER_NAME" == www.bing.com ]]
[[ "$HYSTERIA_SNI" == www.cloudflare.com ]]
TEST_DIR="$(mktemp -d)"
trap 'rm -f -- "$TEST_DIR/config.json"; rmdir -- "$TEST_DIR"' EXIT
log() { :; }
for target in www.cloudflare.com www.microsoft.com www.bing.com custom.example; do
  for SERVER_NAME_SET in 0 1; do
    REALITY_SERVER_NAME="$target"
    MIGRATE_REALITY_TARGET=0
    source <(sed -n '/^  if \[\[ "\$SERVER_NAME_SET" -eq 0 &&/,/^  fi$/p' install.sh)
    expected=0
    if [[ "$SERVER_NAME_SET" == 0 && ( "$target" == www.cloudflare.com || "$target" == www.microsoft.com ) ]]; then
      expected=1
      [[ "$REALITY_SERVER_NAME" == www.bing.com ]]
    else
      [[ "$REALITY_SERVER_NAME" == "$target" ]]
    fi
    [[ "$MIGRATE_REALITY_TARGET" == "$expected" ]]
    XRAY_CONFIG_FILE="$TEST_DIR/config.json"
    printf '{"target":"%s:443","serverNames":["%s"],"id":"keep-uuid","privateKey":"keep-key","shortIds":["keep-sid"]}\n' "$target" "$target" >"$XRAY_CONFIG_FILE"
    source <(sed -n '/^  if \[\[ "\$MIGRATE_REALITY_TARGET" -eq 1/,/^  fi$/p' install.sh)
    if [[ "$expected" == 1 ]]; then
      grep -q '"target":"www.bing.com:443","serverNames":\["www.bing.com"\]' "$XRAY_CONFIG_FILE"
    else
      grep -Fq "\"target\":\"$target:443\"" "$XRAY_CONFIG_FILE"
    fi
    grep -Fq '"id":"keep-uuid","privateKey":"keep-key","shortIds":["keep-sid"]' "$XRAY_CONFIG_FILE"
  done
done
for minimum in absent 1.0.0 26.3.27; do
  printf '{\n  "realitySettings": {\n' >"$XRAY_CONFIG_FILE"
  if [[ "$minimum" != absent ]]; then
    printf '    "minClientVer": "%s",\n' "$minimum" >>"$XRAY_CONFIG_FILE"
  fi
  printf '    "target": "www.bing.com:443",\n    "privateKey": "keep-key"\n  }\n}\n' >>"$XRAY_CONFIG_FILE"
  source <(sed -n '/^  if ! grep -q .*minClientVer/,/^  fi$/p' install.sh)
  expected="$minimum"
  [[ "$minimum" != absent ]] || expected=1.0.0
  grep -Fq "\"minClientVer\": \"$expected\"" "$XRAY_CONFIG_FILE"
  [[ "$(grep -c '"minClientVer"' "$XRAY_CONFIG_FILE")" == 1 ]]
  grep -Fq '"privateKey": "keep-key"' "$XRAY_CONFIG_FILE"
done
printf 'PASS: defaults, saved-target migration, custom targets and credentials\n'
printf 'PASS: third-party client version compatibility and explicit limits\n'
