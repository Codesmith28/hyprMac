#!/bin/bash
# Print a deterministic fingerprint of every piece of system state that
# install.sh may change (sorted, no timestamps).
#
#   scripts/snapshot.sh [-o FILE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) [ $# -ge 2 ] || die "-o needs a file"; out="$2"; shift 2 ;;
        -h | --help) echo "usage: $(basename "$0") [-o FILE]"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

sandbox_guard
if [ -n "$out" ]; then
    take_snapshot >"$out"
else
    take_snapshot
fi
