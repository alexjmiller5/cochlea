#!/usr/bin/env bash
# Called by the app-owned Darwin module as the configured Homebrew user.
set -euo pipefail
phase="${1:?phase}"; prefix="${2:?prefix}"; source="${3:?package bundle}"
destination="${4:?installed bundle}"; enabled="${5:?migration flag}"
applications="${6:-/Applications}"
receipt="$prefix/Caskroom/cochlea/.metadata/INSTALL_RECEIPT.json"
fail() { printf 'Cochlea migration: %s\n' "$*" >&2; exit 1; }
[[ "$phase" == preflight || "$phase" == migrate ]] || fail 'unknown phase'
[[ "$(id -u)" != 0 ]] || fail 'must run as the Homebrew user'
if [[ ! -e "$receipt" ]]; then
  [[ ! -e "$prefix/Caskroom/cochlea" ]] || fail 'orphan cask metadata; review before switching'
  [[ ! -e "$applications/Cochlea.app" ]] || fail 'unmanaged application; review before switching'
  exit 0
fi
[[ "$enabled" == 1 ]] || fail 'enable migrateFromHomebrew before switching this installation'
jq -e '
  .source.tap == "alexjmiller5/tap" and
  .uninstall_flight_blocks == false and
  .uninstall_artifacts == [{"app": ["Cochlea.app"]}]
' "$receipt" >/dev/null || fail 'receipt is not the expected app-only cask'
status=0
pgrep -x Cochlea >/dev/null || status=$?
case "$status" in
  0) fail 'app is running; save work and quit normally before switching' ;;
  1) ;;
  *) fail 'could not inspect running applications' ;;
esac
[[ "$phase" == migrate ]] || exit 0
# applications activation precedes homebrew. Verify publication before removing
# the previous owner; failures abort before Homebrew cleanup=zap can run.
[[ -d "$destination" ]] || fail 'Nix application has not been published'
codesign --verify --deep --strict "$destination" || fail 'Nix application signature is invalid'
diff -qr "$source" "$destination" || fail 'Nix application differs from package'
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 \
  "$prefix/bin/brew" uninstall --cask alexjmiller5/tap/cochlea
[[ ! -e "$receipt" ]] || fail 'uninstall left its receipt; refusing subsequent cleanup'
