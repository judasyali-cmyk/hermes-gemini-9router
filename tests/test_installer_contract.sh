#!/usr/bin/env bash
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/install.sh"
bash -n "$SCRIPT"
grep -q '127.0.0.1:${ROUTER_PORT}:20128' "$SCRIPT"
grep -q "'x-goog-api-key':key" "$SCRIPT"
! grep -q 'models?key=' "$SCRIPT"
grep -q 'api/combos' "$SCRIPT"
grep -q 'hermes gateway --accept-hooks install' "$SCRIPT"
grep -q 'TELEGRAM_BOT_TOKEN' "$SCRIPT"
if grep -Eq 'AIza[0-9A-Za-z_-]{20,}|[0-9]{8,}:[A-Za-z0-9_-]{25,}' "$SCRIPT"; then
  echo 'Potential credential literal in installer' >&2; exit 1
fi
echo 'installer contract tests: PASS'
