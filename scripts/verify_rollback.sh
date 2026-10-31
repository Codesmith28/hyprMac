#!/bin/bash
# Diff a post-uninstall snapshot against the pre-install one.
#
#   scripts/verify_rollback.sh [BEFORE [AFTER]]
#
# Without arguments: BEFORE is the install's before.snapshot (state dir) or,
# after an uninstall, the copy kept in $VERIFY_DIR. AFTER is the after.snapshot
# saved next to it, or a freshly captured snapshot when there is none.
# Exits 1 and prints the diff on any divergence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

case "${1:-}" in
    -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

sandbox_guard
trap cleanup_tmp EXIT

before="${1:-}"
after="${2:-}"
if [ -z "$before" ]; then
    if [ -f "$BEFORE_SNAPSHOT" ]; then
        before="$BEFORE_SNAPSHOT"
        info "hyprMac is still installed; comparing the live state with the pre-install snapshot"
    elif [ -f "$VERIFY_DIR/before.snapshot" ]; then
        before="$VERIFY_DIR/before.snapshot"
        if [ -z "$after" ] && [ -f "$VERIFY_DIR/after.snapshot" ]; then
            after="$VERIFY_DIR/after.snapshot"
        fi
    else
        die "no pre-install snapshot found (looked in $(tilde "$STATE_DIR") and $VERIFY_DIR)"
    fi
fi
if [ -z "$after" ]; then
    make_tmp
    after="$HYPR_TMP/after.snapshot"
    info "capturing a fresh snapshot"
    take_snapshot >"$after"
fi
info "before: $before"
info "after:  $after"
verify_snapshots "$before" "$after"
