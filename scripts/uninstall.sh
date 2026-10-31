#!/bin/bash
# Undo everything install.sh recorded, clean app residue, then verify that the
# system matches the pre-install snapshot.
#
#   scripts/uninstall.sh [--dry-run]
#
# KEEP_CONFIG=1 keeps ~/.config/hyprmac (when install created it).
# Works from the copy inside the app bundle (Contents/Resources/scripts): it
# re-executes from a temporary copy first, because the bundle gets deleted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<USAGE
usage: $(basename "$0") [--dry-run]

Reverses every action recorded in $(tilde "$MANIFEST"), removes the app's
residue (preferences, caches, saved state, notification settings) and checks
the result against the snapshot taken before install. Exits 1 on divergence.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        -n | --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $arg" ;;
    esac
done

sandbox_guard

if [ -z "${HYPR_UNINSTALL_REEXEC:-}" ] && [ -d "$APP_DEST" ]; then
    dest_real="$(cd "$APP_DEST" && pwd -P)"
    case "$SCRIPT_DIR/" in
        "$dest_real"/*)
            reexec_dir="$(/usr/bin/mktemp -d "$_tmp_root/hyprmac-uninstall.XXXXXX")"
            cp -R "$SCRIPT_DIR" "$reexec_dir/scripts"
            HYPR_UNINSTALL_REEXEC="$reexec_dir" exec /bin/bash "$reexec_dir/scripts/uninstall.sh" "$@"
            ;;
    esac
fi

on_exit() {
    cleanup_tmp
    if [ -n "${HYPR_UNINSTALL_REEXEC:-}" ] && [ -d "$HYPR_UNINSTALL_REEXEC" ]; then
        rm -rf "$HYPR_UNINSTALL_REEXEC"
    fi
}
trap on_exit EXIT
trap on_interrupt INT TERM HUP

rc=0
do_uninstall || rc=$?
exit "$rc"
