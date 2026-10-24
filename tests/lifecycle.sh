#!/usr/bin/env bash
# No root, network or systemd needed. All writes stay in a temporary workspace.
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
export TEST_DIR
TEST_CALLS="$TEST_DIR/calls"
export TEST_CALLS

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Read actual installer helpers and actual generated CLI functions, not copies.
source <(sed '/^while (( "\$#" )); do/,$d' install.sh)
sed -n "/^cat <<'CLI_EOF'/,/^CLI_EOF$/p" install.sh | sed '1d;$d' >"$TEST_DIR/cli-body"
{
  printf '#!/usr/bin/env bash\nCLI_VERSION=0.5.0\n'
  declare -f managed_files check_managed_paths backup_installation
  cat "$TEST_DIR/cli-body"
} >"$TEST_DIR/generated-cli"
bash -n install.sh
bash -n "$TEST_DIR/generated-cli"

# Linux ownership/permissions and systemd are simulated; tar and removal are real.
id() {
  case "${1:-}" in -u) printf '0\n' ;; -gn) printf 'root\n' ;; *) return 0 ;; esac
}
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
        fi
        ;;
      *LoadState*) printf 'loaded\n' ;;
    esac
  elif [[ "$1" == stop && "${STOP_FAIL:-0}" == 1 ]]; then
    return 1
  fi
}
tar() {
  printf 'tar %s\n' "$*" >>"$TEST_CALLS"
  [[ "${TAR_FAIL:-0}" == 0 ]] || return 1
  command tar "$@"
}
source <(sed '/^# CLI_DISPATCH/,$d' "$TEST_DIR/cli-body")
CLI_VERSION=0.5.0

fixture() {
  local name="$1" path
  STATE_DIR="$TEST_DIR/$name/etc/liuis-ray"
  STATE_FILE="$STATE_DIR/state.env"
  XRAY_CONFIG_FILE="$TEST_DIR/$name/usr/local/etc/xray/config.json"
  HYSTERIA_CONFIG_DIR="$TEST_DIR/$name/etc/hysteria"
  HYSTERIA_CONFIG_FILE="$HYSTERIA_CONFIG_DIR/config.yaml"
  HYSTERIA_CERT_FILE="$HYSTERIA_CONFIG_DIR/server.crt"
  HYSTERIA_KEY_FILE="$HYSTERIA_CONFIG_DIR/server.key"
  XRAY_UNIT_FILE="$TEST_DIR/$name/etc/systemd/system/xray.service"
  XRAY_HARDENING_FILE="$TEST_DIR/$name/etc/systemd/system/xray.service.d/20-liuis-ray-hardening.conf"
  HYSTERIA_UNIT_FILE="$TEST_DIR/$name/etc/systemd/system/hysteria-server.service"
  CLI_FILE="$TEST_DIR/$name/usr/local/sbin/liuisray"
  LEGACY_CLI_FILE="$TEST_DIR/$name/usr/local/sbin/liuis-ray"
  BACKUP_ROOT="$TEST_DIR/$name/backups"
  while IFS= read -r path; do
    mkdir -p -- "$(dirname -- "$path")"
    printf 'fixture\n' >"$path"
  done < <(managed_files)
  printf 'PROJECT_VERSION=0.5.0\nUUID=keep-this-credential\n' >"$STATE_FILE"
  printf 'unrelated\n' >"$HYSTERIA_CONFIG_DIR/other.yaml"
  : >"$TEST_CALLS"
}

fixture cancelled
confirm_action() { return 1; }
if uninstall_services; then fail 'cancelled uninstall succeeded'; fi
[[ -f "$STATE_FILE" && ! -s "$TEST_CALLS" ]] || {
  # Read-only ownership checks are allowed; stop/disable are not.
  ! grep -Eq '^(stop|disable)' "$TEST_CALLS" || fail 'cancelled uninstall changed services'
  [[ -f "$STATE_FILE" ]] || fail 'cancelled uninstall removed state'
}
pass 'cancel leaves services and files intact'

# Exercise the real non-interactive confirmation guard without /dev/tty.
source <(sed -n '/^confirm_action() {/,/^}/p' "$TEST_DIR/cli-body")
confirm_action UNINSTALL --yes || fail '--yes was not accepted'
if confirm_action UNINSTALL --typo; then fail 'invalid confirmation option accepted'; fi
pass 'explicit automation confirmation and invalid-option rejection'

fixture backup-failure
TAR_FAIL=1
if uninstall_services --yes; then fail 'backup failure ignored'; fi
TAR_FAIL=0
[[ -f "$STATE_FILE" && -f "$CLI_FILE" ]] || fail 'backup failure removed files'
grep -q '^tar ' "$TEST_CALLS" || fail 'backup test never reached archive creation'
! grep -Eq '^(stop|disable)' "$TEST_CALLS" || fail 'backup failure stopped service'
pass 'backup failure blocks service changes and removal'

fixture changed-unit
BAD_OWNER=1
if uninstall_services --yes; then fail 'unrelated service was accepted'; fi
BAD_OWNER=0
[[ -f "$STATE_FILE" ]] || fail 'unrelated service lost state'
! grep -Eq '^(stop|disable)' "$TEST_CALLS" || fail 'unrelated service was stopped'
pass 'changed service ownership blocks uninstall'

fixture stop-failure
STOP_FAIL=1
if uninstall_services --yes; then fail 'stop failure ignored'; fi
STOP_FAIL=0
[[ -f "$STATE_FILE" && -f "$XRAY_CONFIG_FILE" ]] || fail 'stop failure removed config'
grep -q '^stop ' "$TEST_CALLS" || fail 'stop test never reached service stop'
pass 'stop failure preserves files'

fixture uninstall
uninstall_services --yes || fail 'uninstall failed'
while IFS= read -r path; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "managed file survived: $path"
done < <(managed_files)
[[ -f "$HYSTERIA_CONFIG_DIR/other.yaml" ]] || fail 'unrelated config removed'
archive="$(find "$BACKUP_ROOT" -name config.tar.gz -print -quit)"
[[ -s "$archive" ]] || fail 'no backup retained'
command tar -xOf "$archive" "${STATE_FILE#/}" | grep -q keep-this-credential || fail 'backup lost state'
grep -q '^stop xray.service' "$TEST_CALLS" || fail 'primary service not stopped'
grep -q '^disable hysteria-server.service' "$TEST_CALLS" || fail 'secondary service not disabled'
pass 'uninstall removes exact files, preserves unrelated config and readable backup'

fixture missing-state
rm -- "$STATE_FILE"
if (uninstall_services --yes); then fail 'missing state accepted for removal'; fi
[[ -f "$XRAY_CONFIG_FILE" && ! -s "$TEST_CALLS" ]] || fail 'unmanaged config touched'
pass 'missing managed state blocks uninstall'

fixture redirected
rm -- "$XRAY_CONFIG_FILE"
rmdir -- "$(dirname -- "$XRAY_CONFIG_FILE")"
mkdir -p "$TEST_DIR/redirect-target"
# -s may copy instead of link on Windows; only exercise when a link is supported.
if ln -s "$TEST_DIR/redirect-target" "$(dirname -- "$XRAY_CONFIG_FILE")" 2>/dev/null &&
   [[ -L "$(dirname -- "$XRAY_CONFIG_FILE")" ]]; then
  if uninstall_services --yes; then fail 'redirected directory accepted'; fi
  [[ -f "$STATE_FILE" ]] || fail 'redirect guard removed state'
  pass 'redirected managed directory blocks removal'
else
  printf 'SKIP: directory symlinks are unavailable on this host\n'
fi

# Reinstall must download to a file before invoking Bash, preserving error status.
fixture reinstall
cat >"$TEST_DIR/downloaded-installer" <<'EOF'
#!/usr/bin/env bash
printf 'installer %s\n' "$*" >>"$TEST_CALLS"
exit "${INSTALL_FAIL:-0}"
EOF
curl() {
  printf 'download %s\n' "$*" >>"$TEST_CALLS"
  [[ "${DOWNLOAD_FAIL:-0}" == 0 ]] || return 1
  command cp "$TEST_DIR/downloaded-installer" "${@: -1}"
}
reinstall_services --yes || fail 'reinstall command failed'
grep -q 'v0.5.0/install.sh' "$TEST_CALLS" || fail 'reinstall not pinned to CLI version'
grep -q '^installer --reinstall --no-bbr' "$TEST_CALLS" || fail 'wrong reinstall arguments'
pass 'reinstall uses pinned version and credential-preserving mode'

export INSTALL_FAIL=23
result=0
reinstall_services --yes || result=$?
[[ "$result" == 23 ]] || fail 'reinstall swallowed installer error'
unset INSTALL_FAIL
DOWNLOAD_FAIL=1
: >"$TEST_CALLS"
if reinstall_services --yes; then fail 'failed download was executed'; fi
! grep -q '^installer ' "$TEST_CALLS" || fail 'partial download executed'
[[ -f "$STATE_FILE" ]] || fail 'download failure removed state'
pass 'download and installer failures propagate without deleting state'

# Exercise actual installer preflight and config-rendering branches in isolation.
# Credential generation is deliberately forbidden for a repair.
sed -n '/^if \[\[ "\$REINSTALL" -eq 1 && "\$MANAGED_UPGRADE" -ne 1/,/^if \[\[ "\$MANAGED_UPGRADE" -eq 1 \]\] &&/p' \
  install.sh | sed '$d' >"$TEST_DIR/reinstall-preflight"
sed -n '/^if \[\[ "\$MANAGED_UPGRADE" -eq 0 \]\]; then/,/^case "\$(uname -m)" in/p' \
  install.sh | sed '$d; s|/usr/local/bin/xray|test_xray|g' >"$TEST_DIR/render-config"
test_xray() {
  [[ "$1" == run && "$2" == -test ]] || fail 'repair attempted to generate new credentials'
  [[ -s "${@: -1}" ]] || fail 'empty rendered config'
}
fixture rebuild
MANAGED_UPGRADE=1
REINSTALL=1
PRIVATE_SAMPLE="$(printf '%043d' 0)"
UUID=12345678-1234-1234-1234-123456789abc
PUBLIC_KEY=saved-public-key
SHORT_ID=5b005d0b9da0b782
HYSTERIA_AUTH=saved-auth
HYSTERIA_OBFS_PASSWORD=saved-obfs
HYSTERIA_CERT_PIN=saved-pin
XRAY_GROUP=root
TMP_DIR="$TEST_DIR/render-tmp"
mkdir -p "$TMP_DIR"
printf '{"privateKey": "%s"}\n' "$PRIVATE_SAMPLE" >"$XRAY_CONFIG_FILE"
unset PRIVATE_KEY
source "$TEST_DIR/reinstall-preflight"
[[ "$PRIVATE_KEY" == "$PRIVATE_SAMPLE" ]] || fail 'old state private key not recovered'
source "$TEST_DIR/render-config"
grep -q "\"id\": \"$UUID\"" "$XRAY_CONFIG_FILE" || fail 'UUID changed during repair'
grep -q "\"privateKey\": \"$PRIVATE_SAMPLE\"" "$XRAY_CONFIG_FILE" || fail 'private key changed during repair'
grep -q "$SHORT_ID" "$XRAY_CONFIG_FILE" || fail 'short ID changed during repair'
pass 'legacy-state key recovery and config rebuild keep credentials'

rm -- "$XRAY_CONFIG_FILE"
source "$TEST_DIR/reinstall-preflight"
source "$TEST_DIR/render-config"
[[ -s "$XRAY_CONFIG_FILE" ]] || fail 'missing config not repaired from saved private key'
pass 'saved private key allows repair of missing config'

rm -- "$XRAY_CONFIG_FILE"
if (unset PRIVATE_KEY; source "$TEST_DIR/reinstall-preflight"); then fail 'missing private key accepted'; fi
[[ ! -e "$XRAY_CONFIG_FILE" ]] || fail 'failed preflight changed config'
rm -- "$HYSTERIA_CERT_FILE"
if (source "$TEST_DIR/reinstall-preflight"); then fail 'missing pinned certificate accepted'; fi
pass 'missing private key or pinned certificate blocks credential rotation'

REINSTALL=1
MANAGED_UPGRADE=0
if (source "$TEST_DIR/reinstall-preflight"); then fail 'unmanaged reinstall accepted'; fi
pass 'reinstall requires managed installation'

sed -n '/^XRAY_INSTALL_ARGS=(install)/,/^INSTALL_USER=xray bash/p' install.sh |
  sed '$d' >"$TEST_DIR/upstream-args"
REINSTALL=0
rm -- "$XRAY_UNIT_FILE"
source "$TEST_DIR/upstream-args"
[[ "${XRAY_INSTALL_ARGS[*]}" == 'install --force' ]] || fail 'missing service unit not recreated'
printf 'fixture\n' >"$XRAY_UNIT_FILE"
source "$TEST_DIR/upstream-args"
[[ "${XRAY_INSTALL_ARGS[*]}" == install ]] || fail 'normal upgrade unexpectedly forced'
REINSTALL=1
source "$TEST_DIR/upstream-args"
[[ "${XRAY_INSTALL_ARGS[*]}" == 'install --force' ]] || fail 'repair does not force binary reinstall'
pass 'fresh install after uninstall recreates service, repair forces reinstall'

# Confirm the script really emits a complete CLI (including shared helpers).
export -f id
bash "$TEST_DIR/generated-cli" help | grep -q 'uninstall' || fail 'generated CLI help failed'
pass 'installer and emitted CLI syntax/help'
