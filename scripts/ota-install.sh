#!/usr/bin/env bash
# The caller must verify the decrypted IPA first (just ota does this).
set -euo pipefail
exec python3 "$(dirname "$0")/ota-install.py" "$@"
