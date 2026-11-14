#!/bin/bash
# Fill packaging/homebrew/hyprmac.rb with a release's version and sha256.
# Offline: it never talks to GitHub. Download the release zip (or its .sha256
# file) yourself first.
#
#   scripts/release/cask.sh --version 0.3.0 (--zip FILE | --sha256 HEX | --sha256-file FILE)
#                           [--template FILE] [-o FILE]
#
# --zip          hash this file
# --sha256-file  read the hash from a `shasum -a 256` style file ("<hex>  <name>")
# -o             write here instead of stdout (e.g. your tap's Casks/hyprmac.rb)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
template="$ROOT/packaging/homebrew/hyprmac.rb"
version="" sha="" out=""

die() { echo "release/cask.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || die "--version needs a value"; version="${2#v}"; shift 2 ;;
        --sha256) [ $# -ge 2 ] || die "--sha256 needs a value"; sha="$2"; shift 2 ;;
        --sha256-file)
            [ $# -ge 2 ] && [ -f "$2" ] || die "--sha256-file needs an existing file"
            sha="$(/usr/bin/awk 'NF { print $1; exit }' "$2")"; shift 2 ;;
        --zip)
            [ $# -ge 2 ] && [ -f "$2" ] || die "--zip needs an existing file"
            sha="$(/usr/bin/shasum -a 256 <"$2" | /usr/bin/awk '{ print $1 }')"; shift 2 ;;
        --template) [ $# -ge 2 ] || die "--template needs a file"; template="$2"; shift 2 ;;
        -o) [ $# -ge 2 ] || die "-o needs a file"; out="$2"; shift 2 ;;
        -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$version" ] || die "--version is required"
[ -n "$sha" ] || die "one of --zip, --sha256, --sha256-file is required"
[ -f "$template" ] || die "no template at $template"
case "$version" in
    [0-9]*.[0-9]*.[0-9]* ) ;;
    *) die "version must look like 1.2.3, got '$version'" ;;
esac
case "$version" in *[!0-9A-Za-z.+-]*) die "bad characters in version '$version'" ;; esac
sha="$(printf '%s' "$sha" | /usr/bin/tr 'A-F' 'a-f')"
case "$sha" in
    *[!0-9a-f]* | '') die "sha256 must be 64 hex characters" ;;
esac
[ "${#sha}" = 64 ] || die "sha256 must be 64 hex characters, got ${#sha}"

filled="$(/usr/bin/sed -E \
    -e "s|^([[:space:]]*version )\"[^\"]*\"|\\1\"$version\"|" \
    -e "s|^([[:space:]]*sha256 )\"[^\"]*\"|\\1\"$sha\"|" "$template")"
printf '%s\n' "$filled" | /usr/bin/grep -q "^  version \"$version\"" || die "template has no 'version' line"
printf '%s\n' "$filled" | /usr/bin/grep -q "^  sha256 \"$sha\"" || die "template has no 'sha256' line"

if [ -n "$out" ]; then
    printf '%s\n' "$filled" >"$out"
else
    printf '%s\n' "$filled"
fi
