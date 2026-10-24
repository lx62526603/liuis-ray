#!/usr/bin/env bash
# No root/network/systemd required. Mutations are restricted to a test directory.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
PROJECT_DIR="$PWD"
TEST_DIR="$(mktemp -d "${PROJECT_DIR}/.lifecycle-test.XXXXXX")"
cleanup() {
  local resolved
  resolved="$(realpath -m -- "$TEST_DIR")"
  case "$resolved" in
    "$PROJECT_DIR"/.lifecycle-test.*) rm -rf -- "$resolved" ;;
    *) printf 'Refusing unexpected cleanup path: %s\n' "$resolved" >&2 ;;
  esac
}
trap cleanup EXIT
TEST_CALLS="$TEST_DIR/calls"
export TEST_DIR TEST_CALLS
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

source <(sed '/^while (( "\$#" )); do/,$d' install.sh)
sed -n "/^cat <<'CLI_EOF'/,/^CLI_EOF$/p" install.sh | sed '1d;$d' >"$TEST_DIR/cli-body"
{
  printf '#!/usr/bin/env bash\nCLI_VERSION=%q\n' "$INSTALLER_VERSION"
  declare -f managed_files check_managed_paths backup_installation check_service_ownership \
    check_exclusive_installation clean_installation verify_services download_verified prepare_payloads
  cat "$TEST_DIR/cli-body"
} >"$TEST_DIR/generated-cli"
bash -n install.sh
bash -n "$TEST_DIR/generated-cli"

# Model Linux ownership/permissions and systemd; archive and removal are real.
id() { printf '0\n'; }
stat() {
  case "${2:-}" in '%u') printf '0\n' ;; '%a') printf '600\n' ;; *) command stat "$@" ;; esac
}
install() {
  local path
  local -a args=()
  while (($#)); do
    case "$1" in -o|-g|-m) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  for path in "${args[@]}"; do
    case "$path" in -d|"$TEST_DIR"/*) ;; *) fail "install outside sandbox: $path" ;; esac
  done
  if [[ "${args[0]}" == -d ]]; then
    command mkdir -p -- "${args[@]:1}"
  else
    command cp -- "${args[@]}"
  fi
}
chmod() { return 0; }
chown() { return 0; }
sleep() { return 0; }
journalctl() { printf 'journal %s\n' "$*" >>"$TEST_CALLS"; }
systemctl() {
  printf '%s\n' "$*" >>"$TEST_CALLS"
  if [[ "$1" == show ]]; then
    case "$*" in
      *ExecStart*)
        if [[ "${BAD_OWNER:-0}" == 1 ]]; then
          printf '/another-service --config /another/config\n'
        elif [[ "$2" == xray.service ]]; then
          printf '/usr/local/bin/xray run -config %s\n' "$XRAY_CONFIG_FILE"
        else
          printf '/usr/local/bin/hysteria server --config %s\n' "$HYSTERIA_CONFIG_FILE"
        fi ;;
      *LoadState*) printf 'loaded\n' ;;
      *NRestarts*)
        if [[ "${RESTART_LOOP:-0}" == 1 ]] &&
           (( $(grep -c NRestarts "$TEST_CALLS") > 1 )); then printf '1\n'; else printf '0\n'; fi ;;
    esac
  elif [[ "$1" == stop && "${STOP_FAIL:-0}" == 1 ]]; then
    return 1
  elif [[ "$1" == list-units && "${EXTRA_INSTANCE:-0}" == 1 ]]; then
    printf 'xray@other.service loaded active running Other instance\n'
  fi
}
tar() {
  printf 'tar %s\n' "$*" >>"$TEST_CALLS"
  [[ "${TAR_FAIL:-0}" == 0 ]] || return 1
  command tar "$@"
}
source <(sed '/^# CLI_DISPATCH/,$d' "$TEST_DIR/cli-body")
CLI_VERSION="$INSTALLER_VERSION"

fixture() {
  local base="$TEST_DIR/$1" path
  STATE_DIR="$base/etc/liuis-ray"; STATE_FILE="$STATE_DIR/state.env"
  XRAY_CONFIG_FILE="$base/usr/local/etc/xray/config.json"
  HYSTERIA_CONFIG_DIR="$base/etc/hysteria"
  HYSTERIA_CONFIG_FILE="$HYSTERIA_CONFIG_DIR/config.yaml"
  HYSTERIA_CERT_FILE="$HYSTERIA_CONFIG_DIR/server.crt"
  HYSTERIA_KEY_FILE="$HYSTERIA_CONFIG_DIR/server.key"
  XRAY_UNIT_FILE="$base/etc/systemd/system/xray.service"
  XRAY_TEMPLATE_UNIT="$base/etc/systemd/system/xray@.service"
  XRAY_HARDENING_FILE="${XRAY_UNIT_FILE}.d/20-liuis-ray-hardening.conf"
  HYSTERIA_UNIT_FILE="$base/etc/systemd/system/hysteria-server.service"
  CLI_FILE="$base/usr/local/sbin/liuisray"; LEGACY_CLI_FILE="$base/usr/local/sbin/liuis-ray"
  XRAY_BINARY="$base/usr/local/bin/xray"; HYSTERIA_BINARY="$base/usr/local/bin/hysteria"
  XRAY_DATA_DIR="$base/usr/local/share/xray"; XRAY_LOG_DIR="$base/var/log/xray"
  XRAY_LOGROTATE="$base/etc/logrotate.d/xray"; BACKUP_ROOT="$base/backups"
  while IFS= read -r path; do
    mkdir -p -- "$(dirname -- "$path")"
    printf 'fixture\n' >"$path"
  done < <(managed_files)
  printf 'PROJECT_VERSION=0.5.0\nUUID=old-credential\n' >"$STATE_FILE"
  printf 'old config\n' >"${XRAY_CONFIG_FILE}.backup.20260728T120000Z"
  printf '[Service]\nUser=root\n' >"${XRAY_UNIT_FILE}.d/10-old-override.conf"
  printf 'unrelated\n' >"$(dirname -- "$XRAY_CONFIG_FILE")/notes.txt"
  : >"$TEST_CALLS"
}

fixture no-prompt
check_lifecycle_option || fail 'default command requires extra input'
check_lifecycle_option --yes || fail 'legacy --yes compatibility broken'
if check_lifecycle_option --typo; then fail 'invalid option accepted'; fi
! grep -Eq '/dev/tty|confirm_action' "$TEST_DIR/generated-cli" || fail 'confirmation prompt remains'
pass 'lifecycle commands run without confirmation and reject invalid flags'

fixture backup-failure
TAR_FAIL=1
if uninstall_services </dev/null; then fail 'failed backup ignored'; fi
TAR_FAIL=0
[[ -f "$STATE_FILE" && -f "$XRAY_BINARY" ]] || fail 'backup failure removed files'
grep -q '^tar ' "$TEST_CALLS" || fail 'test did not reach archiving'
! grep -Eq '^(stop|disable)' "$TEST_CALLS" || fail 'backup failure changed services'
pass 'backup failure prevents cleanup'

fixture changed-service
BAD_OWNER=1
if uninstall_services; then fail 'another service was removed'; fi
BAD_OWNER=0
[[ -f "$STATE_FILE" ]] || fail 'another service lost files'
! grep -Eq '^(stop|disable)' "$TEST_CALLS" || fail 'another service was stopped'
pass 'changed service ownership blocks cleanup'

fixture shared-config
printf 'unrelated\n' >"$HYSTERIA_CONFIG_DIR/other.yaml"
if uninstall_services; then fail 'shared runtime was deleted'; fi
[[ -f "$XRAY_BINARY" ]] || fail 'shared binary removed'
pass 'additional config blocks deletion of shared programs'

fixture extra-instance
EXTRA_INSTANCE=1
if uninstall_services; then fail 'additional instance ignored'; fi
EXTRA_INSTANCE=0
[[ -f "$STATE_FILE" ]] || fail 'additional instance lost state'
pass 'additional service instance blocks cleanup'

fixture shared-service
printf '[Service]\nExecStart=%s -config /srv/other.json\n' "$XRAY_BINARY" >"$(dirname -- "$XRAY_UNIT_FILE")/other-node.service"
if uninstall_services; then fail 'additional service sharing binary was ignored'; fi
[[ -f "$XRAY_BINARY" && -f "$STATE_FILE" ]] || fail 'shared service lost runtime'
pass 'other service files sharing the binary block cleanup'

fixture stop-failure
STOP_FAIL=1
if uninstall_services; then fail 'failed service stop ignored'; fi
STOP_FAIL=0
[[ -f "$STATE_FILE" && -f "$XRAY_BINARY" ]] || fail 'failed stop removed runtime'
grep -q '^stop ' "$TEST_CALLS" || fail 'test did not reach service stop'
pass 'stop failure preserves installation'

fixture uninstall
mapfile -t expected_files < <(managed_files)
uninstall_services </dev/null || fail 'uninstall failed without input'
for path in "${expected_files[@]}"; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "old managed file survived: $path"
done
[[ -f "$(dirname -- "$XRAY_CONFIG_FILE")/notes.txt" ]] || fail 'unrelated file removed'
archive="$(find "$BACKUP_ROOT" -name config.tar.gz -print -quit)"
[[ -s "$archive" ]] || fail 'recovery archive missing'
command tar -xOf "$archive" "${STATE_FILE#/}" | grep -q old-credential || fail 'archive lost credentials'
command tar -tf "$archive" | grep -q '10-old-override.conf' || fail 'archive lost old overrides'
pass 'uninstall clears binaries/configs/credentials/overrides/backups and retains recovery archive'

fixture missing-state
rm -- "$STATE_FILE"
if (uninstall_services); then fail 'missing managed state accepted'; fi
[[ -f "$XRAY_BINARY" && ! -s "$TEST_CALLS" ]] || fail 'unmanaged installation touched'
pass 'missing state prevents unmanaged cleanup'

fixture reinstall-command
cat >"$TEST_DIR/downloaded-installer" <<'EOF'
#!/usr/bin/env bash
printf 'installer %s\n' "$*" >>"$TEST_CALLS"
exit "${INSTALL_FAIL:-0}"
EOF
curl() {
  printf 'download %s\n' "$*" >>"$TEST_CALLS"
  [[ "${DOWNLOAD_FAIL:-0}" == 0 ]] || return 1
  command cp -- "${DOWNLOAD_SOURCE:-$TEST_DIR/downloaded-installer}" "${@: -1}"
}
reinstall_services </dev/null || fail 'reinstall required confirmation'
grep -q "v${CLI_VERSION}/install.sh" "$TEST_CALLS" || fail 'installer version not pinned'
grep -q '^installer --reinstall --no-bbr' "$TEST_CALLS" || fail 'not using clean install mode'
export INSTALL_FAIL=23
result=0
reinstall_services || result=$?
[[ "$result" == 23 ]] || fail 'installer error swallowed'
unset INSTALL_FAIL
DOWNLOAD_FAIL=1
: >"$TEST_CALLS"
if reinstall_services; then fail 'failed download executed'; fi
DOWNLOAD_FAIL=0
! grep -q '^installer ' "$TEST_CALLS" || fail 'partial script executed'
pass 'reinstall needs no input, pins version and propagates download/installer errors'

fixture payload-validation
DOWNLOAD_SOURCE="$(type -P true)"
XRAY_SHA256="$(command sha256sum "$DOWNLOAD_SOURCE" | awk '{print $1}')"
HYSTERIA_SHA256="$XRAY_SHA256"
XRAY_URL=https://example.invalid/a; HYSTERIA_URL=https://example.invalid/b
unzip() { command cp -- "$DOWNLOAD_SOURCE" "${@: -1}/xray"; }
mkdir -p "$TEST_DIR/payloads"
prepare_payloads "$TEST_DIR/payloads" || fail 'valid payload preparation failed'
HYSTERIA_SHA256="$(printf '%064d' 0)"
if prepare_payloads "$TEST_DIR/payloads"; then fail 'incorrect digest accepted'; fi
pass 'both payload hashes are checked before runtime preparation succeeds'

fixture prepare-failure
REINSTALL=1; MANAGED_UPGRADE=1; UUID=old-credential
# Preserve actual payload helper so following tests can restore it.
saved_prepare="$(declare -f prepare_payloads)"
prepare_payloads() { return 1; }
if prepare_installation "$TEST_DIR/payloads"; then fail 'payload failure ignored'; fi
[[ -f "$STATE_FILE" && "$UUID" == old-credential ]] || fail 'payload failure wiped installation'
! grep -Eq '^(stop|disable)' "$TEST_CALLS" || fail 'payload failure stopped services'
pass 'downloads finish before cleanup starts'

fixture fresh-reinstall
REINSTALL=1; MANAGED_UPGRADE=1
UUID=old-uuid; PRIVATE_KEY=old-private; PUBLIC_KEY=old-public; SHORT_ID=old-short
HYSTERIA_AUTH=old-auth; HYSTERIA_OBFS_PASSWORD=old-obfs; HYSTERIA_CERT_PIN=old-pin
prepare_payloads() { printf 'payloads ready\n' >>"$TEST_CALLS"; }
prepare_installation "$TEST_DIR/payloads" || fail 'clean reinstall preparation failed'
[[ "$MANAGED_UPGRADE" == 0 && ! ${UUID+x} && ! ${PRIVATE_KEY+x} && ! ${HYSTERIA_AUTH+x} && ! ${HYSTERIA_CERT_PIN+x} ]] ||
  fail 'old credential variables survived clean install'
[[ ! -e "$XRAY_BINARY" && ! -e "$HYSTERIA_CERT_FILE" && ! -e "$STATE_FILE" ]] || fail 'old runtime files survived'
[[ "$(head -n 1 "$TEST_CALLS")" == 'payloads ready' ]] || fail 'cleanup ran before payload download'
pass 'clean reinstall wipes old programs, certificates and every saved credential'
eval "$saved_prepare"

fixture hardening
XRAY_GROUP=xray
write_xray_hardening || fail 'could not render service permissions'
# Simulate systemd's OR inheritance, including empty-assignment resets. A root
# base unit with no capabilities and an older unit with NET_ADMIN both end up
# with only the port-binding capability, without running the service as root.
effective="$( { printf '[Service]\nCapabilityBoundingSet=CAP_NET_ADMIN\nAmbientCapabilities=CAP_NET_ADMIN\n'; cat "$XRAY_HARDENING_FILE"; } |
  awk -F= '/^(CapabilityBoundingSet|AmbientCapabilities)=/ {
    if ($2 == "") {for (key in caps) if (index(key, $1 ":") == 1) delete caps[key]}
    else {n=split($2, values, " "); for(i=1;i<=n;i++) caps[$1 ":" values[i]]=1}
  } END {for(key in caps) print key}' | sort )"
[[ "$effective" == $'AmbientCapabilities:CAP_NET_BIND_SERVICE\nCapabilityBoundingSet:CAP_NET_BIND_SERVICE' ]] || fail 'wrong effective port-binding permissions'
grep -q '^User=xray$' "$XRAY_HARDENING_FILE" || fail 'service became root'
pass 'service has port-binding capability without inherited admin permissions'

: >"$TEST_CALLS"
verify_services xray hysteria-server || fail 'stable services rejected'
RESTART_LOOP=1
: >"$TEST_CALLS"
if verify_services xray; then fail 'active-but-restarting service accepted'; fi
RESTART_LOOP=0
pass 'startup check catches restart loops even when sampled state is active'

export -f id
bash "$TEST_DIR/generated-cli" help | grep -q 'without a confirmation' || fail 'emitted CLI failed'
pass 'installer and generated management command syntax/help'
