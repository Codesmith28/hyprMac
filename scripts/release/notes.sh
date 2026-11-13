#!/bin/bash
# Print the GitHub release notes for a version: its CHANGELOG.md section
# followed by the install/signing footer (.github/release_notes_footer.md).
#
#   scripts/release/notes.sh VERSION [--changelog FILE] [--footer FILE] [--sha256 HEX]
#
# VERSION may carry a leading "v". The section runs from "## [VERSION]" to the
# next "## [" heading or "---" rule. Exits 1 when the version has no section
# (so a release never goes out with empty notes). Pure text processing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
changelog="$ROOT/CHANGELOG.md"
footer="$ROOT/.github/release_notes_footer.md"
sha="<sha256 is in the .sha256 file next to the zip>"
version=""

die() { echo "release/notes.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --changelog) [ $# -ge 2 ] || die "--changelog needs a file"; changelog="$2"; shift 2 ;;
        --footer) [ $# -ge 2 ] || die "--footer needs a file"; footer="$2"; shift 2 ;;
        --sha256) [ $# -ge 2 ] || die "--sha256 needs a value"; sha="$2"; shift 2 ;;
        -h | --help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [ -z "$version" ] || die "one VERSION only"; version="${1#v}"; shift ;;
    esac
done
[ -n "$version" ] || die "usage: notes.sh VERSION [--changelog FILE] [--footer FILE] [--sha256 HEX]"
[ -f "$changelog" ] || die "no changelog at $changelog"

section="$(/usr/bin/awk -v want="## [$version]" '
    index($0, want) == 1 { on = 1; next }
    on && (/^## \[/ || /^---[ \t]*$/) { exit }
    on { print }
' "$changelog")"
# Trim leading and trailing blank lines.
section="$(printf '%s\n' "$section" | /usr/bin/sed -e '/./,$!d' | /usr/bin/sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"
[ -n "$section" ] || die "CHANGELOG has no (or an empty) section for [$version]"

printf '%s\n' "$section"
if [ -f "$footer" ]; then
    printf '\n'
    /usr/bin/sed -e "s|{{VERSION}}|$version|g" -e "s|{{SHA256}}|$sha|g" "$footer"
fi
