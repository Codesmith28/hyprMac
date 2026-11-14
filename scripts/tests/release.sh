#!/bin/bash
# Tests for scripts/release/{notes,cask}.sh (run by `make scripts-test`).
# Pure text processing in a temp dir: no network, no system state. Output is TAP.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$(dirname "$HERE")")"
NOTES="$ROOT/scripts/release/notes.sh"
CASK="$ROOT/scripts/release/cask.sh"
FIX="$HERE/fixtures/CHANGELOG.fixture.md"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hyprmac-release-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FOOTER="$TMP/footer.md"
printf 'v={{VERSION}} sha={{SHA256}}\n' >"$FOOTER"
SHA="$(printf 'cd%.0s' {1..32})"

N=0 FAILED=0
CUR_OK=1
bad() { printf '# FAIL: %s\n' "$*"; CUR_OK=0; }
contains() { case "$2" in *"$3"*) ;; *) bad "$1: lacks [$3]" ;; esac; }
not_contains() { case "$2" in *"$3"*) bad "$1: unexpectedly has [$3]" ;; esac; }
eq() { [ "$2" = "$3" ] || bad "$1: expected [$2] got [$3]"; }

tap() { # name function
    N=$((N + 1))
    CUR_OK=1
    local out
    out="$("$2" 2>&1)"
    if [ "$CUR_OK" = 1 ]; then echo "ok $N - $1"; else echo "not ok $N - $1"; FAILED=$((FAILED + 1)); fi
    [ -z "$out" ] || printf '%s\n' "$out"
}

t_notes_section() {
    local out
    out="$("$NOTES" 1.2.0 --changelog "$FIX" --footer "$FOOTER" --sha256 "$SHA")"
    contains "has added" "$out" "**Thing**: Does a thing."
    contains "keeps special chars" "$out" 'Fixed with `code` and a | pipe & ampersand.'
    not_contains "no heading" "$out" "## [1.2.0]"
    not_contains "stops at the rule" "$out" "Older"
    not_contains "no intro" "$out" "Intro text"
    contains "footer filled" "$out" "v=1.2.0 sha=$SHA"
    eq "starts with the first section line" "### 🚀 Added" "$(printf '%s\n' "$out" | head -1)"
}

t_notes_v_prefix_and_last_section() {
    local out
    out="$("$NOTES" v1.0.0-rc.1 --changelog "$FIX" --footer "$FOOTER")"
    contains "last section" "$out" "Release candidate (no trailing rule)."
    not_contains "other sections" "$out" "Older"
    out="$("$NOTES" 1.1.0 --changelog "$FIX" --footer "$FOOTER")"
    contains "middle section" "$out" "**Older**"
    not_contains "next section" "$out" "Does a thing"
}

t_notes_missing_version_fails() {
    local out rc=0
    out="$("$NOTES" 9.9.9 --changelog "$FIX" --footer "$FOOTER" 2>&1)" || rc=$?
    eq "exit code" 1 "$rc"
    contains "says why" "$out" "no (or an empty) section for [9.9.9]"
    # A prefix of a real version must not match (1.2 vs 1.2.0).
    rc=0; "$NOTES" 1.2 --changelog "$FIX" >/dev/null 2>&1 || rc=$?
    eq "no prefix match" 1 "$rc"
    rc=0; "$NOTES" 1.2.0 --changelog "$TMP/nope.md" >/dev/null 2>&1 || rc=$?
    eq "missing changelog" 1 "$rc"
}

t_notes_real_changelog_and_footer() {
    local v out
    v="$(/usr/bin/sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$ROOT/CHANGELOG.md" | head -1)"
    [ -n "$v" ] || { bad "no version in CHANGELOG.md"; return; }
    out="$("$NOTES" "$v" --sha256 "$SHA")"
    contains "real changelog section" "$out" "###"
    contains "default footer says ad-hoc" "$out" "ad-hoc signed"
    contains "default footer names the zip" "$out" "hyprMac-$v.zip"
    contains "footer has the hash" "$out" "$SHA"
}

t_cask_fill() {
    local out
    out="$("$CASK" --version v0.3.0 --sha256 "$SHA")"
    contains "version" "$out" '  version "0.3.0"'
    contains "sha" "$out" "  sha256 \"$SHA\""
    contains "url uses the version" "$out" 'v#{version}/hyprMac-#{version}.zip'
    not_contains "no placeholder" "$out" '"0.0.0"'
    # Only those two lines change.
    eq "diff is two lines" 4 "$(diff <(cat "$ROOT/packaging/homebrew/hyprmac.rb") <(printf '%s\n' "$out") | grep -c '^[<>]')"
}

t_cask_inputs() {
    printf 'hello' >"$TMP/a.zip"
    local want got
    want="$(/usr/bin/shasum -a 256 <"$TMP/a.zip" | cut -d' ' -f1)"
    got="$("$CASK" --version 1.0.0 --zip "$TMP/a.zip" | sed -n 's/^  sha256 "\(.*\)"/\1/p')"
    eq "--zip hashes the file" "$want" "$got"
    printf '%s  hyprMac-1.0.0.zip\n' "$want" >"$TMP/a.zip.sha256"
    got="$("$CASK" --version 1.0.0 --sha256-file "$TMP/a.zip.sha256" | sed -n 's/^  sha256 "\(.*\)"/\1/p')"
    eq "--sha256-file" "$want" "$got"
    "$CASK" --version 1.0.0 --sha256 "$(printf '%s' "$want" | tr a-f A-F)" -o "$TMP/out.rb" >/dev/null
    contains "-o writes, hex is lower-cased" "$(cat "$TMP/out.rb")" "sha256 \"$want\""
}

t_cask_rejects_bad_input() {
    local rc
    rc=0; "$CASK" --version 1.0.0 --sha256 abc >/dev/null 2>&1 || rc=$?; eq "short sha" 1 "$rc"
    rc=0; "$CASK" --version 1.0.0 --sha256 "$(printf 'zz%.0s' {1..32})" >/dev/null 2>&1 || rc=$?; eq "non-hex sha" 1 "$rc"
    rc=0; "$CASK" --version 'x"; rm' --sha256 "$SHA" >/dev/null 2>&1 || rc=$?; eq "bad version" 1 "$rc"
    rc=0; "$CASK" --sha256 "$SHA" >/dev/null 2>&1 || rc=$?; eq "no version" 1 "$rc"
    rc=0; "$CASK" --version 1.0.0 >/dev/null 2>&1 || rc=$?; eq "no hash" 1 "$rc"
    printf 'cask "x" do\nend\n' >"$TMP/bad.rb"
    rc=0; "$CASK" --version 1.0.0 --sha256 "$SHA" --template "$TMP/bad.rb" >/dev/null 2>&1 || rc=$?; eq "template without placeholders" 1 "$rc"
}

echo "TAP version 13"
tap "r1 release notes: the version's section plus the footer" t_notes_section
tap "r2 release notes: v prefix, last and middle sections" t_notes_v_prefix_and_last_section
tap "r3 release notes: missing version or changelog fails" t_notes_missing_version_fails
tap "r4 release notes: the real CHANGELOG and default footer" t_notes_real_changelog_and_footer
tap "r5 cask helper fills only version and sha256" t_cask_fill
tap "r6 cask helper: --zip, --sha256-file, -o" t_cask_inputs
tap "r7 cask helper rejects bad versions and hashes" t_cask_rejects_bad_input
echo "1..$N"
if [ "$FAILED" -gt 0 ]; then echo "# FAILED $FAILED of $N"; exit 1; fi
echo "# all $N passed"
