# shellcheck shell=bash
# Shared prologue for the bash shims: refuse to run outside the sandbox, log
# the call, and honour FAKE_FAIL ("cmd args-prefix|other prefix").
set -euo pipefail
[ "${HYPR_SANDBOX:-}" = 1 ] && [ -n "${FAKE_STATE:-}" ] && [ -d "$FAKE_STATE" ] || {
    echo "shim $(basename "$0"): not in a sandbox, refusing" >&2; exit 97; }
SHIM_NAME="$(basename "$0")"
printf '%s %s\n' "$SHIM_NAME" "$*" >>"$FAKE_STATE/calls.log"
if [ -n "${FAKE_FAIL:-}" ]; then
    _call="$SHIM_NAME $*"
    IFS='|' read -r -a _pats <<<"$FAKE_FAIL"
    for _p in "${_pats[@]}"; do
        case "$_call" in "$_p"*) echo "$SHIM_NAME: injected failure ($_p)" >&2; exit 1 ;; esac
    done
fi
