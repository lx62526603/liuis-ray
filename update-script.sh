#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CLI_FILE=/usr/local/sbin/liuisray
SOURCE_URL=https://raw.githubusercontent.com/lx62526603/liuis-ray/main/install.sh

render_manager() (
  local installer="$1" output="$2"
  bash -n "$installer"
  [[ "$(grep -Fc 'while (( "$#" )); do' "$installer")" == 1 ]]
  [[ "$(grep -c "^cat <<'CLI_EOF'$" "$installer")" == 1 ]]
  [[ "$(grep -c '^CLI_EOF$' "$installer")" == 1 ]]
  # Load only declarations preceding the installer's argument parsing.
  source <(sed '/^while (( "\$#" )); do/,$d' "$installer")
  [[ "$INSTALLER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  {
    printf '#!/usr/bin/env bash\n'
    declare -f managed_files check_managed_paths backup_installation check_service_ownership \
      check_exclusive_installation clean_installation verify_services download_verified prepare_payloads
    printf 'CLI_VERSION=%q\n' "$INSTALLER_VERSION"
    sed -n "/^cat <<'CLI_EOF'/,/^CLI_EOF$/p" "$installer" | sed '1d;$d'
  } >"$output"
  bash -n "$output"
  grep -q '^# CLI_DISPATCH' "$output"
)

update_manager() {
  [[ "$(id -u)" == 0 ]] || { echo 'Run as root.' >&2; return 1; }
  command -v curl >/dev/null || { echo 'curl is required.' >&2; return 1; }
  [[ -f "$CLI_FILE" && ! -L "$CLI_FILE" ]] || { echo 'Existing regular liuisray manager not found.' >&2; return 1; }
  local temp staged='' backup
  temp="$(mktemp -d)"
  cleanup_update() {
    [[ -z "$staged" ]] || rm -f -- "$staged"
    rm -f -- "$temp/install.sh" "$temp/manager"
    rmdir -- "$temp"
  }
  trap cleanup_update EXIT
  curl -fLsS --retry 3 --connect-timeout 15 --max-time 90 "$SOURCE_URL" -o "$temp/install.sh"
  render_manager "$temp/install.sh" "$temp/manager"
  bash "$temp/manager" help >/dev/null
  backup="$(mktemp "${CLI_FILE}.backup.XXXXXXXX")"
  cp -p -- "$CLI_FILE" "$backup"
  staged="$(mktemp "${CLI_FILE}.new.XXXXXXXX")"
  install -m 755 -o root -g root "$temp/manager" "$staged"
  mv -f -- "$staged" "$CLI_FILE"
  staged=''
  printf 'Management script updated. Backup: %s\n' "$backup"
  printf 'Run liuisray to open the updated menu. Cores, services, configs and credentials were not changed.\n'
  cleanup_update
  trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then update_manager "$@"; fi
