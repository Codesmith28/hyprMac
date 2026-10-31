#!/bin/bash
# Sandboxed tests for install.sh / uninstall.sh (run by `make scripts-test`).
#
# Every scenario gets a fresh fake HOME under $TMPDIR, shims for every command
# variable (scripts/tests/shims) and a fake hyprMac.app whose binary, when
# "launched" by the fake launchctl, creates the usual runtime residue.
# Nothing here touches the real system. Output is TAP.
#
#   scripts/tests/run.sh [name-filter]      VERBOSE=1 shows all output
#                                           KEEP_TMP=1 keeps the sandboxes
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(dirname "$HERE")"
ROOT="$(dirname "$SCRIPTS")"
FILTER="${1:-}"
REAL_TMP="${TMPDIR:-/tmp}"
REAL_TMP="${REAL_TMP%/}"
ROOT_TMP="$(/usr/bin/mktemp -d "$REAL_TMP/hyprmac-tests.XXXXXX")"
[ "${KEEP_TMP:-0}" = 1 ] || trap 'rm -rf "$ROOT_TMP"' EXIT

BID="dev.codesmith28.hyprmac"
N=0
FAILED=0
FAILED_NAMES=""

# ------------------------------------------------------------- assertions --
note() { printf '# %s\n' "$*"; }
bad() { note "FAIL: $*"; CUR_OK=0; }
check() { # description command...
    local d="$1"; shift
    "$@" || bad "$d"
}
eq() { # description expected actual
    [ "$2" = "$3" ] || bad "$1: expected [$2] got [$3]"
}
contains() { # description haystack needle
    case "$2" in *"$3"*) ;; *) bad "$1: output lacks [$3]" ;; esac
}
not_contains() {
    case "$2" in *"$3"*) bad "$1: output unexpectedly contains [$3]" ;; esac
}

# --------------------------------------------------------------- sandbox --
setup_sandbox() { # name
    S="$ROOT_TMP/$1"
    mkdir -p "$S/home" "$S/bin" "$S/state" "$S/tmp" "$S/src"
    cp "$HERE"/shims/* "$S/bin/"
    : >"$S/state/calls.log"
    export HOME="$S/home" TMPDIR="$S/tmp/" HYPR_SANDBOX=1 FAKE_STATE="$S/state" FAKE_ROOT="$S"
    export UID_VAL=501 NO_COLOR=1
    export DEFAULTS="$S/bin/defaults" PLUTIL="$S/bin/plutil" LAUNCHCTL="$S/bin/launchctl"
    export TCCUTIL="$S/bin/tccutil" LSREGISTER="$S/bin/lsregister" ACTIVATE_SETTINGS="$S/bin/activateSettings"
    export OPEN="$S/bin/open" PKILL="$S/bin/pkill" KILLALL="$S/bin/killall"
    export PYTHON="$S/bin/python3"
    unset HYPR_FAIL_AT FAKE_FAIL KEEP_CONFIG HYPR_WM_APPLY_CMD HYPR_WM_ACTIVE_CMD DRY_RUN HYPR_VERIFY_DIR \
        HYPR_UNINSTALL_REEXEC FAKE_DEFAULTS_IGNORE_WRITE OSASCRIPT
    local d
    for d in Applications "Library/Preferences" "Library/Caches" "Library/HTTPStorages" \
             "Library/Saved Application State" "Library/Application Support" "Library/Logs/DiagnosticReports"; do
        mkdir -p "$HOME/$d"
    done
    seed_prefs
    make_fake_app "$S/src/hyprMac.app" 1
    export APP_SRC="$S/src/hyprMac.app"
}

# Writes the initial preference domains exactly like the fake defaults does.
seed_prefs() {
    /usr/bin/python3 -I - "$HOME/Library/Preferences" <<'PY'
import os, plistlib, sys
prefs = sys.argv[1]
def save(dom, d):
    with open(os.path.join(prefs, dom + ".plist"), "wb") as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_BINARY, sort_keys=True)
hk = {}
for i, (ch, kc) in enumerate([(49, 18), (50, 19), (51, 20), (52, 21), (53, 23), (54, 22), (55, 26)]):
    hk[str(118 + i)] = {"enabled": True, "value": {"parameters": [ch, kc, 524288], "type": "standard"}}
hk["60"] = {"enabled": True, "value": {"parameters": [32, 49, 262144], "type": "standard"}}
save("com.apple.symbolichotkeys", {"AppleSymbolicHotKeys": hk})
save("com.apple.WindowManager", {"GloballyEnabled": True, "AutoHide": False})
save("com.apple.ncprefs", {
    "apps": [
        {"bundle-id": "com.apple.FaceTime", "flags": 41951246, "path": "/System/Applications/FaceTime.app",
         "src": [{"flags": 6, "req": b"\xfa\xde\x0c\x00", "uuid": "52D4094F"}]},
        {"bundle-id": "com.example.chat", "flags": 8396814, "path": "/Applications/Chat.app"},
    ],
    "dnd_prefs": b"\x62\x70\x6c\x69\x73\x74",
})
PY
}

make_fake_app() { # dir version
    local app="$1"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/scripts/lib"
    cp "$ROOT/macos/Resources/Info.plist" "$app/Contents/Info.plist"
    cp "$ROOT/config/init.lua.example" "$app/Contents/Resources/"
    cp "$SCRIPTS"/*.sh "$app/Contents/Resources/scripts/"
    cp "$SCRIPTS"/lib/*.sh "$app/Contents/Resources/scripts/lib/"
    printf '%s\n' "$2" >"$app/Contents/Resources/version"
    cat >"$app/Contents/MacOS/hyprMac" <<'APP'
#!/bin/bash
# Fake hyprMac: simulates the residue a first launch leaves behind.
[ "${HYPR_SANDBOX:-}" = 1 ] && [ -n "${FAKE_STATE:-}" ] && [ -n "${FAKE_ROOT:-}" ] || exit 0
case "$HOME" in "$FAKE_ROOT"/*) ;; *) exit 0 ;; esac
BID=dev.codesmith28.hyprmac
"$DEFAULTS" write "$BID" LaunchCount -int 1
mkdir -p "$HOME/Library/Caches/$BID" && echo cache >"$HOME/Library/Caches/$BID/Cache.db"
mkdir -p "$HOME/Library/HTTPStorages/$BID" && : >"$HOME/Library/HTTPStorages/$BID.binarycookies"
mkdir -p "$HOME/Library/Saved Application State/$BID.savedState"
echo state >"$HOME/Library/Saved Application State/$BID.savedState/windows.plist"
/usr/bin/python3 -I - "$HOME/Library/Preferences/com.apple.ncprefs.plist" "$BID" <<'PY'
import plistlib, sys
p, bid = sys.argv[1:3]
with open(p, "rb") as f: d = plistlib.load(f)
mine = [a for a in d.setdefault("apps", []) if a.get("bundle-id") == bid]
if mine:
    mine[0]["flags"] = 41951246  # the running app changes its own entry
else:
    d["apps"].append({"bundle-id": bid, "flags": 41951246, "path": "/fake/hyprMac.app"})
with open(p, "wb") as f: plistlib.dump(d, f, fmt=plistlib.FMT_BINARY, sort_keys=True)
PY
mkdir -p "$HOME/Library/Logs/hyprMac" && echo started >>"$HOME/Library/Logs/hyprMac/hyprMac.log"
echo crash >"$HOME/Library/Logs/DiagnosticReports/hyprMac-2026-10-31-120000.ips"
printf '%s' "${FAKE_STARTED_BY:-manual}" >"$FAKE_STATE/running"
APP
    chmod +x "$app/Contents/MacOS/hyprMac"
}

# Fingerprint of the whole fake HOME plus the fake system state.
sys_fp() {
    (
        cd "$HOME" || exit 1
        /usr/bin/find . -print | LC_ALL=C sort | while IFS= read -r f; do
            if [ -L "$f" ]; then printf 'l %s\n' "$f"
            elif [ -d "$f" ]; then printf 'd %s %s\n' "$f" "$(stat -f %Lp "$f")"
            else printf 'f %s %s %s\n' "$f" "$(stat -f %Lp "$f")" "$(shasum -a 256 <"$f" | cut -c1-16)"; fi
        done
    )
    echo "launchd: $(sort "$FAKE_STATE/launchd.loaded" 2>/dev/null | tr '\n' ' ')"
    echo "lsregister: $(sort "$FAKE_STATE/lsregister.db" 2>/dev/null | tr '\n' ' ')"
    echo "running: $([ -e "$FAKE_STATE/running" ] && echo yes || echo no)"
}

same_fp() { # description file-with-earlier-fp
    local now
    now="$(sys_fp)"
    if [ "$now" != "$(cat "$2")" ]; then
        bad "$1: system differs from the pre-install state"
        diff <(cat "$2") <(printf '%s\n' "$now") | sed 's/^/#   /' | head -40
    fi
}

# pref DOMAIN KEYPATH -> canonical JSON or "absent"
pref() {
    /usr/bin/python3 -I - "$HOME/Library/Preferences/$1.plist" "$2" <<'PY'
import json, os, plistlib, sys
p, kp = sys.argv[1:3]
if not os.path.exists(p): print("absent"); sys.exit()
with open(p, "rb") as f: cur = plistlib.load(f)
for part in kp.split("."):
    if isinstance(cur, dict) and part in cur: cur = cur[part]
    else: print("absent"); sys.exit()
def c(v):
    if isinstance(v, bytes): return v.hex()
    if isinstance(v, dict): return {k: c(x) for k, x in v.items()}
    if isinstance(v, list): return [c(x) for x in v]
    return v
print(json.dumps(c(cur), sort_keys=True, separators=(",", ":")))
PY
}

set_pref() { # DOMAIN KEYPATH JSON  (JSON null deletes)
    /usr/bin/python3 -I - "$HOME/Library/Preferences/$1.plist" "$2" "$3" <<'PY'
import json, os, plistlib, sys
p, kp, val = sys.argv[1:4]
d = {}
if os.path.exists(p):
    with open(p, "rb") as f: d = plistlib.load(f)
parts = kp.split(".")
cur = d
for part in parts[:-1]: cur = cur.setdefault(part, {})
v = json.loads(val)
if v is None: cur.pop(parts[-1], None)
else: cur[parts[-1]] = v
with open(p, "wb") as f: plistlib.dump(d, f, fmt=plistlib.FMT_BINARY, sort_keys=True)
PY
}

nc_ids() {
    /usr/bin/python3 -I -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(" ".join(a["bundle-id"] for a in d.get("apps",[])))' \
        "$HOME/Library/Preferences/com.apple.ncprefs.plist"
}

OUT=""
RC=0
inst() { OUT="$("$SCRIPTS/install.sh" "$@" 2>&1)"; RC=$?; [ "${VERBOSE:-0}" = 1 ] && printf '%s\n' "$OUT" | sed 's/^/#   | /'; return 0; }
uninst() { OUT="$("$SCRIPTS/uninstall.sh" "$@" 2>&1)"; RC=$?; [ "${VERBOSE:-0}" = 1 ] && printf '%s\n' "$OUT" | sed 's/^/#   | /'; return 0; }
show_out() { printf '%s\n' "$OUT" | tail -25 | sed 's/^/#   | /'; }
expect_rc() { # description expected
    if [ "$RC" != "$2" ]; then bad "$1: exit $RC, expected $2"; show_out; fi
}
STATE_DIR_REL="Library/Application Support/hyprMac/install"
MUTATING='^(defaults (write|delete|import)|launchctl (bootstrap|bootout|kill)|tccutil|lsregister -[fu]|open|killall|activateSettings|pkill -(TERM|KILL))'

# Clean install + uninstall with the zero-diff checks every scenario shares.
roundtrip() { # label
    local fp="$S/fp.before"
    sys_fp >"$fp"
    inst; expect_rc "$1 install" 0
    uninst; expect_rc "$1 uninstall" 0
    contains "$1 uninstall verifies" "$OUT" "rollback verified"
    same_fp "$1" "$fp"
}

# -------------------------------------------------------------- scenarios --
t_clean_roundtrip() {
    local fp="$S/fp.before"
    sys_fp >"$fp"
    inst; expect_rc "install" 0
    check "app installed" test -x "$HOME/Applications/hyprMac.app/Contents/MacOS/hyprMac"
    check "manifest exists" test -f "$HOME/$STATE_DIR_REL/manifest"
    check "before.snapshot exists" test -s "$HOME/$STATE_DIR_REL/before.snapshot"
    eq "hotkey 125" '{"enabled":true,"value":{"parameters":[56,28,524288],"type":"standard"}}' \
        "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.125)"
    eq "hotkey 126" '{"enabled":true,"value":{"parameters":[57,25,524288],"type":"standard"}}' \
        "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.126)"
    eq "stage manager off" false "$(pref com.apple.WindowManager GloballyEnabled)"
    local plist="$HOME/Library/LaunchAgents/$BID.plist"
    eq "agent Label" "$BID" "$(/usr/bin/plutil -extract Label raw "$plist")"
    eq "agent program" "$HOME/Applications/hyprMac.app/Contents/MacOS/hyprMac" \
        "$(/usr/bin/plutil -extract ProgramArguments.0 raw "$plist")"
    eq "agent RunAtLoad" true "$(/usr/bin/plutil -extract RunAtLoad raw "$plist")"
    eq "agent KeepAlive" false "$(/usr/bin/plutil -extract KeepAlive raw "$plist")"
    eq "agent ProcessType" Interactive "$(/usr/bin/plutil -extract ProcessType raw "$plist")"
    eq "agent session" Aqua "$(/usr/bin/plutil -extract LimitLoadToSessionType raw "$plist")"
    check "agent loaded" grep -qx "$BID" "$FAKE_STATE/launchd.loaded"
    check "lsregister -f" grep -q "^lsregister -f $HOME/Applications/hyprMac.app" "$FAKE_STATE/calls.log"
    check "tcc reset" grep -q "^tccutil reset Accessibility $BID" "$FAKE_STATE/calls.log"
    check "settings opened" grep -q "^open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" "$FAKE_STATE/calls.log"
    check "activateSettings -u" grep -q "^activateSettings -u" "$FAKE_STATE/calls.log"
    check "config created" cmp -s "$HOME/.config/hyprmac/init.lua" "$ROOT/config/init.lua.example"
    check "residue: prefs" test -f "$HOME/Library/Preferences/$BID.plist"
    check "residue: logs" test -f "$HOME/Library/Logs/hyprMac/hyprMac.log"
    eq "lsregister counts only the installed path (not the plug-in)" \
        "lsregister ~/Applications/hyprMac.app records=1" "$(HYPR_SANDBOX=1 "$SCRIPTS/snapshot.sh" | grep '^lsregister')"
    check "residue: ncprefs" grep -q "$BID" <<<"$(nc_ids)"
    check "app running" test -e "$FAKE_STATE/running"

    : >"$FAKE_STATE/calls.log"
    uninst; expect_rc "uninstall" 0
    contains "verification ran" "$OUT" "rollback verified"
    check "SIGTERM through launchd" grep -q "^launchctl kill SIGTERM gui/501/$BID" "$FAKE_STATE/calls.log"
    check "no pkill needed" test -z "$(grep -E '^pkill -(TERM|KILL)' "$FAKE_STATE/calls.log")"
    check "app stopped" test ! -e "$FAKE_STATE/running"
    check "logs removed" test ! -e "$HOME/Library/Logs/hyprMac"
    check "new crash report removed" test ! -e "$HOME/Library/Logs/DiagnosticReports/hyprMac-2026-10-31-120000.ips"
    check "bootout" grep -q "^launchctl bootout gui/501/$BID" "$FAKE_STATE/calls.log"
    check "lsregister -u" grep -q "^lsregister -u" "$FAKE_STATE/calls.log"
    check "defaults delete own domain" grep -q "^defaults delete $BID\$" "$FAKE_STATE/calls.log"
    check "killall usernoted" grep -q "^killall usernoted" "$FAKE_STATE/calls.log"
    check "tcc reset again" grep -q "^tccutil reset Accessibility $BID" "$FAKE_STATE/calls.log"
    check "state dir gone" test ! -e "$HOME/Library/Application Support/hyprMac"
    check "after.snapshot kept" test -s "$S/tmp/hyprmac-verify-501/after.snapshot"
    check "snapshots identical" cmp -s "$S/tmp/hyprmac-verify-501/before.snapshot" "$S/tmp/hyprmac-verify-501/after.snapshot"
    check "no temp dirs left" test -z "$(/bin/ls "$S/tmp" | grep -v '^hyprmac-verify-501$')"
    same_fp "clean roundtrip" "$fp"
}

t_upgrade() {
    local fp="$S/fp.before" m1 s1
    sys_fp >"$fp"
    inst; expect_rc "first install" 0
    m1="$(cat "$HOME/$STATE_DIR_REL/manifest")"
    s1="$(cat "$HOME/$STATE_DIR_REL/before.snapshot")"
    make_fake_app "$APP_SRC" 2
    inst; expect_rc "second install (upgrade)" 0
    contains "upgrade path taken" "$OUT" "replacing the app bundle only"
    eq "new app version" 2 "$(cat "$HOME/Applications/hyprMac.app/Contents/Resources/version")"
    eq "manifest unchanged" "$m1" "$(cat "$HOME/$STATE_DIR_REL/manifest")"
    eq "before.snapshot unchanged" "$s1" "$(cat "$HOME/$STATE_DIR_REL/before.snapshot")"
    check "agent reloaded" grep -qx "$BID" "$FAKE_STATE/launchd.loaded"
    uninst; expect_rc "uninstall" 0
    eq "original Stage Manager value restored" true "$(pref com.apple.WindowManager GloballyEnabled)"
    eq "125 removed" absent "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.125)"
    same_fp "upgrade roundtrip" "$fp"
}

t_uninstall_without_install() {
    local fp="$S/fp.before"
    sys_fp >"$fp"
    uninst; expect_rc "uninstall" 0
    contains "says nothing to undo" "$OUT" "nothing to undo"
    check "no mutating calls" test -z "$(grep -E "$MUTATING" "$FAKE_STATE/calls.log")"
    same_fp "no-op uninstall" "$fp"
}

t_hotkey_preexisting() {
    local custom='{"enabled":false,"value":{"parameters":[65535,100,1179648],"type":"standard"}}'
    set_pref com.apple.symbolichotkeys AppleSymbolicHotKeys.125 "$custom"
    local fp="$S/fp.before"
    sys_fp >"$fp"
    inst; expect_rc "install" 0
    eq "125 untouched" "$custom" "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.125)"
    eq "126 added" '{"enabled":true,"value":{"parameters":[57,25,524288],"type":"standard"}}' \
        "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.126)"
    check "manifest says untouched" grep -qx "hotkey 125 untouched" "$HOME/$STATE_DIR_REL/manifest"
    uninst; expect_rc "uninstall" 0
    eq "125 still custom" "$custom" "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.125)"
    eq "126 removed" absent "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.126)"
    same_fp "preexisting 125" "$fp"
}

t_stage_manager_values() {
    local v expected
    for v in absent true false 1 2.5 domain-absent; do
        setup_sandbox "stage-$v"
        export HYPR_WM_APPLY_CMD="echo applied >>'$FAKE_STATE/wm-apply.log'"
        case "$v" in
            absent) set_pref com.apple.WindowManager GloballyEnabled null; expected=absent ;;
            true | false) set_pref com.apple.WindowManager GloballyEnabled "$v"; expected="$v" ;;
            1) set_pref com.apple.WindowManager GloballyEnabled 1; expected=1 ;;
            2.5) set_pref com.apple.WindowManager GloballyEnabled 2.5; expected=2.5 ;;
            domain-absent) rm -f "$HOME/Library/Preferences/com.apple.WindowManager.plist"; expected=absent ;;
        esac
        local fp="$S/fp.before"
        sys_fp >"$fp"
        inst; expect_rc "[$v] install" 0
        eq "[$v] stage manager off during install" false "$(pref com.apple.WindowManager GloballyEnabled)"
        uninst; expect_rc "[$v] uninstall" 0
        eq "[$v] restored with exact type" "$expected" "$(pref com.apple.WindowManager GloballyEnabled)"
        eq "[$v] HYPR_WM_APPLY_CMD ran on install and uninstall" 2 "$(wc -l <"$FAKE_STATE/wm-apply.log" | tr -d ' ')"
        if [ "$v" = domain-absent ]; then
            check "[$v] domain removed again" test ! -e "$HOME/Library/Preferences/com.apple.WindowManager.plist"
        fi
        same_fp "stage manager $v" "$fp"
    done
}

t_failure_at_each_step() {
    local s fp
    for s in snapshot state_dir residue_scan app lsregister hotkeys wm wm_verify config launchagent_plist \
             accessibility launchagent_load open_settings done; do
        setup_sandbox "fail-$s"
        fp="$S/fp.before"
        sys_fp >"$fp"
        export HYPR_FAIL_AT="$s"
        inst
        [ "$RC" != 0 ] || bad "[$s] install should fail"
        contains "[$s] reports step" "$OUT" "install failed during step '$s'"
        case "$s" in snapshot | state_dir) ;; *) contains "[$s] rollback verified" "$OUT" "rollback verified" ;; esac
        check "[$s] no state dir left" test ! -e "$HOME/Library/Application Support/hyprMac"
        same_fp "failure at $s" "$fp"
    done
    for s in "launchctl bootstrap" "lsregister -f" "defaults import com.apple.symbolichotkeys" \
             "defaults write com.apple.WindowManager GloballyEnabled -bool false" "tccutil reset" "plutil -lint"; do
        setup_sandbox "fail-shim-$(printf '%s' "$s" | tr ' .' '__')"
        fp="$S/fp.before"
        sys_fp >"$fp"
        export FAKE_FAIL="$s"
        inst
        [ "$RC" != 0 ] || bad "[$s] install should fail"
        contains "[$s] rollback verified" "$OUT" "rollback verified"
        unset FAKE_FAIL
        same_fp "shim failure: $s" "$fp"
    done
}

t_config_preexisting() {
    mkdir -p "$HOME/.config/hyprmac"
    printf 'config = { gaps = { inner = 3 } }\n' >"$HOME/.config/hyprmac/init.lua"
    roundtrip "preexisting config"
    eq "user config kept" 'config = { gaps = { inner = 3 } }' "$(cat "$HOME/.config/hyprmac/init.lua")"
}

t_keep_config() {
    local fp="$S/fp.before"
    sys_fp >"$fp"
    inst; expect_rc "install" 0
    echo "-- edited" >>"$HOME/.config/hyprmac/init.lua"
    KEEP_CONFIG=1 uninst
    expect_rc "uninstall" 0
    contains "verification ran" "$OUT" "rollback verified"
    check "config kept" grep -q -- "-- edited" "$HOME/.config/hyprmac/init.lua"
    check "app removed" test ! -e "$HOME/Applications/hyprMac.app"
    check "state dir removed" test ! -e "$HOME/Library/Application Support/hyprMac"
    eq "stage manager restored" true "$(pref com.apple.WindowManager GloballyEnabled)"
    rm -rf "$HOME/.config"
    same_fp "keep config (minus ~/.config)" "$fp"
}

t_ncprefs_changed_entry() {
    local fp="$S/fp.before" faceTime
    faceTime="$(pref com.apple.ncprefs apps.0)"
    sys_fp >"$fp"
    inst; expect_rc "install" 0
    /usr/bin/python3 -I - "$HOME/Library/Preferences/com.apple.ncprefs.plist" "$BID" <<'PY'
import plistlib, sys
p, bid = sys.argv[1:3]
d = plistlib.load(open(p, "rb"))
for a in d["apps"]:
    if a["bundle-id"] == bid: a["flags"] = 1; a["grouping"] = 2
open(p, "wb").write(plistlib.dumps(d, fmt=plistlib.FMT_BINARY, sort_keys=True))
PY
    uninst; expect_rc "uninstall" 0
    eq "our entry removed, others kept in order" "com.apple.FaceTime com.example.chat" "$(nc_ids)"
    eq "other entry byte-identical" "$faceTime" "$(pref com.apple.ncprefs apps.0)"
    same_fp "ncprefs" "$fp"
}

t_unrelated_hotkey_change() {
    inst; expect_rc "install" 0
    local mine='{"enabled":true,"value":{"parameters":[97,0,1572864],"type":"standard"}}'
    set_pref com.apple.symbolichotkeys AppleSymbolicHotKeys.118 "$mine"
    uninst; expect_rc "uninstall (diff expected 0: 118 is not in the snapshot)" 0
    eq "user's 118 change preserved" "$mine" "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.118)"
    eq "125 removed" absent "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.125)"
    eq "126 removed" absent "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.126)"
    eq "119 untouched" '{"enabled":true,"value":{"parameters":[50,19,524288],"type":"standard"}}' \
        "$(pref com.apple.symbolichotkeys AppleSymbolicHotKeys.119)"
}

t_dry_run() {
    local fp="$S/fp.before"
    sys_fp >"$fp"
    inst --dry-run; expect_rc "dry-run install" 0
    contains "prints actions" "$OUT" "[dry-run]"
    contains "prints the bootstrap" "$OUT" "launchctl bootstrap gui/501"
    check "no mutating calls" test -z "$(grep -E "$MUTATING" "$FAKE_STATE/calls.log")"
    same_fp "dry-run install" "$fp"
    inst; expect_rc "real install" 0
    sys_fp >"$S/fp.installed"
    : >"$FAKE_STATE/calls.log"
    uninst --dry-run; expect_rc "dry-run uninstall" 0
    contains "prints undo actions" "$OUT" "[dry-run]"
    check "no mutating calls (uninstall)" test -z "$(grep -E "$MUTATING" "$FAKE_STATE/calls.log")"
    same_fp "dry-run uninstall" "$S/fp.installed"
    uninst; expect_rc "real uninstall" 0
    same_fp "after real uninstall" "$fp"
}

t_uninstall_from_bundle() {
    local fp="$S/fp.before"
    sys_fp >"$fp"
    mkdir -p "$S/repo"
    cp -R "$SCRIPTS" "$S/repo/scripts"
    OUT="$("$S/repo/scripts/install.sh" 2>&1)"; RC=$?
    expect_rc "install from temp repo" 0
    rm -rf "$S/repo"
    local u="$HOME/Applications/hyprMac.app/Contents/Resources/scripts/uninstall.sh"
    check "bundle has uninstall.sh" test -x "$u"
    OUT="$("$u" 2>&1)"; RC=$?
    expect_rc "uninstall from bundle" 0
    contains "verified" "$OUT" "rollback verified"
    check "re-exec temp copy cleaned" test -z "$(/bin/ls "$S/tmp" | grep hyprmac-uninstall)"
    same_fp "in-bundle uninstall" "$fp"
}

t_sandbox_guard() {
    # Decoys: /usr/bin/true is a "real system path" but harmless if the guard
    # were broken. Combined with --dry-run for extra safety.
    local v saved
    for v in DEFAULTS PLUTIL LAUNCHCTL TCCUTIL LSREGISTER ACTIVATE_SETTINGS OPEN PKILL KILLALL PYTHON; do
        saved="${!v}"
        export "$v=/usr/bin/true"
        inst --dry-run
        [ "$RC" != 0 ] || bad "guard accepted $v=/usr/bin/true"
        contains "guard names $v" "$OUT" "$v points at a real system path"
        uninst --dry-run
        [ "$RC" != 0 ] || bad "uninstall guard accepted $v=/usr/bin/true"
        OUT="$("$SCRIPTS/snapshot.sh" 2>&1)" && bad "snapshot guard accepted $v"
        export "$v=$saved"
    done
    # Real HOME is refused too (all commands are inert no-op shims here).
    mkdir -p "$S/inert"
    for v in defaults plutil launchctl tccutil lsregister activateSettings open pkill killall python3; do
        printf '#!/bin/sh\nexit 1\n' >"$S/inert/$v"; chmod +x "$S/inert/$v"
    done
    OUT="$(HOME="$(eval "printf '%s' ~$(id -un)")" DEFAULTS="$S/inert/defaults" PLUTIL="$S/inert/plutil" \
        LAUNCHCTL="$S/inert/launchctl" TCCUTIL="$S/inert/tccutil" LSREGISTER="$S/inert/lsregister" \
        ACTIVATE_SETTINGS="$S/inert/activateSettings" OPEN="$S/inert/open" \
        PKILL="$S/inert/pkill" KILLALL="$S/inert/killall" PYTHON="$S/inert/python3" \
        "$SCRIPTS/install.sh" --dry-run 2>&1)" && bad "guard accepted the real HOME"
    contains "guard names HOME" "$OUT" "HOME is the real home directory"
    check "no shim was called" test ! -s "$FAKE_STATE/calls.log"
}

t_verify_detects_divergence() {
    inst; expect_rc "install" 0
    uninst; expect_rc "uninstall" 0
    OUT="$("$SCRIPTS/verify_rollback.sh" 2>&1)"; RC=$?
    expect_rc "verify on clean state" 0
    mkdir -p "$HOME/Library/Caches/$BID"
    rm "$S/tmp/hyprmac-verify-501/after.snapshot"
    OUT="$("$SCRIPTS/verify_rollback.sh" 2>&1)"; RC=$?
    expect_rc "verify with stray residue (fresh capture)" 1
    contains "diff printed" "$OUT" "+path ~/Library/Caches/$BID dir"
    contains "fresh capture used" "$OUT" "capturing a fresh snapshot"
    OUT="$("$SCRIPTS/verify_rollback.sh" "$S/tmp/hyprmac-verify-501/before.snapshot" "$S/tmp/hyprmac-verify-501/before.snapshot" 2>&1)"; RC=$?
    expect_rc "explicit identical files" 0
    # A divergence right after uninstall makes uninstall itself fail.
    rm -rf "$HOME/Library/Caches/$BID"
    inst; expect_rc "reinstall" 0
    printf 'x' >"$HOME/Library/Application Support/hyprMac/install/../user-data"
    uninst; expect_rc "uninstall with leftover user data in support dir" 1
    contains "uninstall reports divergence" "$OUT" "rollback verification FAILED"
}

t_preexisting_residue_and_app() {
    # Data from an earlier dev build, and an unrelated hyprMac.app at the destination.
    mkdir -p "$HOME/Library/Caches/$BID" && echo old >"$HOME/Library/Caches/$BID/old"
    set_pref "$BID" Old '"value"'
    mkdir -p "$HOME/Applications/hyprMac.app/Contents" && echo mine >"$HOME/Applications/hyprMac.app/Contents/marker"
    mkdir -p "$HOME/Library/LaunchAgents"
    : >"$HOME/Library/HTTPStorages/$BID.binarycookies"
    /usr/bin/python3 -I - "$HOME/Library/Preferences/com.apple.ncprefs.plist" "$BID" <<'PY'
import plistlib, sys
p, bid = sys.argv[1:3]
d = plistlib.load(open(p, "rb"))
d["apps"].insert(1, {"bundle-id": bid, "flags": 7, "path": "/old/hyprMac.app"})
open(p, "wb").write(plistlib.dumps(d, fmt=plistlib.FMT_BINARY, sort_keys=True))
PY
    local entry
    entry="$(pref com.apple.ncprefs apps.1)"
    roundtrip "preexisting residue"
    eq "old ncprefs entry restored in place" "$entry" "$(pref com.apple.ncprefs apps.1)"
    eq "ncprefs order" "com.apple.FaceTime $BID com.example.chat" "$(nc_ids)"
    eq "old prefs restored" '"value"' "$(pref "$BID" Old)"
    eq "app's own pref gone" absent "$(pref "$BID" LaunchCount)"
    check "old cache has no new files" test ! -e "$HOME/Library/Caches/$BID/Cache.db"
    eq "old cache kept" old "$(cat "$HOME/Library/Caches/$BID/old")"
    eq "old app restored" mine "$(cat "$HOME/Applications/hyprMac.app/Contents/marker")"
    check "LaunchAgents dir kept" test -d "$HOME/Library/LaunchAgents"
}

t_no_activate_settings() {
    export ACTIVATE_SETTINGS="$S/bin/does-not-exist"
    roundtrip "no activateSettings"
    contains "logout warning" "$OUT" "log out and back in"
}

t_missing_app_src() {
    export APP_SRC="$S/nowhere/hyprMac.app"
    inst; expect_rc "install without APP_SRC" 1
    contains "explains" "$OUT" "no app bundle at"
    check "nothing created" test ! -e "$HOME/Library/Application Support/hyprMac"
}

t_quit_paths() {
    # a) started by launchd: SIGTERM via launchctl kill, no pkill.
    inst; expect_rc "install" 0
    eq "started by launchd" launchd "$(cat "$FAKE_STATE/running")"
    : >"$FAKE_STATE/calls.log"
    uninst; expect_rc "uninstall (launchd)" 0
    check "launchctl kill SIGTERM" grep -q "^launchctl kill SIGTERM gui/501/$BID" "$FAKE_STATE/calls.log"
    check "no pkill -TERM/-KILL" test -z "$(grep -E '^pkill -(TERM|KILL)' "$FAKE_STATE/calls.log")"

    # b) agent loaded but the running copy was started by hand: launchctl kill
    #    has no process, so pkill -TERM.
    setup_sandbox "quit-manual"
    inst; expect_rc "install" 0
    printf manual >"$FAKE_STATE/running"
    : >"$FAKE_STATE/calls.log"
    uninst; expect_rc "uninstall (manual)" 0
    check "pkill -TERM used" grep -q "^pkill -TERM -x hyprMac" "$FAKE_STATE/calls.log"
    check "no SIGKILL" test -z "$(grep -E '^pkill -KILL' "$FAKE_STATE/calls.log")"
    check "stopped" test ! -e "$FAKE_STATE/running"

    # c) app ignores SIGTERM: SIGKILL after ~3 s.
    setup_sandbox "quit-stubborn"
    local fp="$S/fp.before"
    sys_fp >"$fp"
    inst; expect_rc "install" 0
    touch "$FAKE_STATE/ignore-term"
    : >"$FAKE_STATE/calls.log"
    local t0 t1
    t0="$(date +%s)"
    uninst; expect_rc "uninstall (stubborn)" 0
    t1="$(date +%s)"
    contains "warns before SIGKILL" "$OUT" "did not exit within 3 s; sending SIGKILL"
    check "pkill -KILL used" grep -q "^pkill -KILL -x hyprMac" "$FAKE_STATE/calls.log"
    check "waited about 3 s" test $((t1 - t0)) -ge 3
    rm -f "$FAKE_STATE/ignore-term"
    same_fp "stubborn app roundtrip" "$fp"

    # d) nothing running: no signals at all. And no Apple Events anywhere.
    setup_sandbox "quit-none"
    inst; rm -f "$FAKE_STATE/running"; : >"$FAKE_STATE/calls.log"
    uninst; expect_rc "uninstall (not running)" 0
    check "no signals sent" test -z "$(grep -E '^(launchctl kill|pkill -(TERM|KILL))' "$FAKE_STATE/calls.log")"
    check "no osascript in the scripts" test -z "$(grep -rl osascript "$SCRIPTS"/*.sh "$SCRIPTS"/lib)"
}

t_lsregister_build_copies() {
    # Spotlight/Finder register build copies on their own, before and during
    # the install. Only the installed path counts.
    "$LSREGISTER" -f "$APP_SRC"
    local fp="$S/fp.before"
    sys_fp >"$fp"
    inst; expect_rc "install" 0
    check "before.snapshot counts 0 installed records" \
        grep -qx "lsregister ~/Applications/hyprMac.app records=0" "$HOME/$STATE_DIR_REL/before.snapshot"
    mkdir -p "$S/other/build" && make_fake_app "$S/other/build/hyprMac.app" 9
    "$LSREGISTER" -f "$S/other/build/hyprMac.app"
    uninst; expect_rc "uninstall with an extra build copy registered" 0
    contains "verified" "$OUT" "rollback verified"
    check "build copies untouched" grep -q "$S/other/build/hyprMac.app" "$FAKE_STATE/lsregister.db"
    "$LSREGISTER" -u "$S/other/build/hyprMac.app"
    same_fp "lsregister build copies" "$fp"
}

t_stage_manager_verify() {
    # Previously on: install reads back 0 and prints the logout/toggle note,
    # also in the final summary; uninstall notes the re-enable.
    inst; expect_rc "install" 0
    contains "readback ok" "$OUT" "GloballyEnabled reads back as off"
    contains "note shown" "$OUT" "Stage Manager change applies after logout or toggle in Control Center"
    contains "note in summary" "$OUT" "note: Stage Manager change applies"
    check "WindowManager never restarted" test -z "$(grep -E '^killall' "$FAKE_STATE/calls.log")"
    uninst; expect_rc "uninstall" 0
    contains "uninstall note" "$OUT" "Stage Manager restored to enabled"

    setup_sandbox "wm-was-off"
    set_pref com.apple.WindowManager GloballyEnabled false
    inst; expect_rc "install (was off)" 0
    not_contains "no note when it was already off" "$OUT" "Stage Manager change applies"

    setup_sandbox "wm-probe"
    export HYPR_WM_ACTIVE_CMD="exit 1"
    inst; expect_rc "install (probe says inactive)" 0
    not_contains "probe overrides heuristic" "$OUT" "Stage Manager change applies"

    setup_sandbox "wm-readback-fails"
    local fp="$S/fp.before"
    sys_fp >"$fp"
    export FAKE_DEFAULTS_IGNORE_WRITE="com.apple.WindowManager"
    inst
    [ "$RC" != 0 ] || bad "install must fail when the value does not read back as off"
    contains "explains" "$OUT" "reads back as '1' after writing false"
    contains "rolled back" "$OUT" "rollback verified"
    same_fp "readback failure" "$fp"
}

t_crash_reports() {
    local old="$HOME/Library/Logs/DiagnosticReports/hyprMac-2026-10-01-090000.ips"
    local other="$HOME/Library/Logs/DiagnosticReports/Finder-2026-10-01-090000.ips"
    echo "dev build crash" >"$old"
    echo "not ours" >"$other"
    mkdir -p "$HOME/Library/Logs/hyprMac" && echo "dev log" >"$HOME/Library/Logs/hyprMac/hyprMac.log"
    local fp="$S/fp.before"
    sys_fp >"$fp"
    inst; expect_rc "install" 0
    contains "pre-existing crash report backed up" "$OUT" "hyprMac-2026-10-01-090000.ips already exists"
    echo "rewritten" >"$old"
    uninst; expect_rc "uninstall" 0
    eq "old crash report restored" "dev build crash" "$(cat "$old")"
    eq "old log restored" "dev log" "$(cat "$HOME/Library/Logs/hyprMac/hyprMac.log")"
    check "new crash report removed" test ! -e "$HOME/Library/Logs/DiagnosticReports/hyprMac-2026-10-31-120000.ips"
    eq "other apps' reports untouched" "not ours" "$(cat "$other")"
    same_fp "crash reports" "$fp"
}

t_make_dry_run() {
    local out
    out="$(env -u DRY_RUN make -s -C "$ROOT" -n install DRY_RUN=1 2>/dev/null | grep 'scripts/install.sh')"
    contains "make install DRY_RUN=1" "$out" "scripts/install.sh --dry-run"
    out="$(env -u DRY_RUN make -s -C "$ROOT" -n install 2>/dev/null | grep 'scripts/install.sh')"
    not_contains "make install" "$out" "--dry-run"
    out="$(env -u DRY_RUN make -s -C "$ROOT" -n uninstall DRY_RUN=1)"
    contains "make uninstall DRY_RUN=1" "$out" "scripts/uninstall.sh --dry-run"
    out="$(env -u DRY_RUN make -s -C "$ROOT" -n uninstall)"
    not_contains "make uninstall" "$out" "--dry-run"
    out="$(env -u DRY_RUN make -s -C "$ROOT" -n preflight)"
    contains "make preflight" "$out" "scripts/install.sh --preflight"
}

t_preflight() {
    local custom='{"enabled":true,"value":{"parameters":[65535,100,1179648],"type":"standard"}}'
    set_pref com.apple.symbolichotkeys AppleSymbolicHotKeys.125 "$custom"
    echo crash >"$HOME/Library/Logs/DiagnosticReports/hyprMac-2026-10-01-090000.ips"
    local fp="$S/fp.before"
    sys_fp >"$fp"
    : >"$FAKE_STATE/calls.log"
    inst --preflight; expect_rc "preflight" 0
    contains "header" "$OUT" "read-only"
    contains "125 bound" "$OUT" "already bound to"
    contains "126 absent" "$OUT" 'absent → would add ⌥9 "Switch to Desktop 9"'
    contains "stage manager" "$OUT" "GloballyEnabled = true (bool)"
    contains "agent" "$OUT" "not loaded → would be bootstrapped"
    contains "config" "$OUT" "~/.config/hyprmac        absent"
    contains "activateSettings" "$OUT" "present → shortcut changes apply"
    contains "crash report" "$OUT" "hyprMac-2026-10-01-090000.ips → backed up"
    local sys_calls
    sys_calls="$(grep -E '^(defaults|launchctl|tccutil|lsregister|open|pkill|killall|activateSettings) ' "$FAKE_STATE/calls.log" |
        grep -vE '^(defaults (export|read) |launchctl print )')"
    [ -z "$sys_calls" ] || bad "non-read-only calls: $sys_calls"
    check "defaults export only to stdout" test -z "$(grep -E '^defaults export [^ ]+ [^-]' "$FAKE_STATE/calls.log")"
    check "no temp files" test -z "$(/bin/ls -A "$S/tmp")"
    same_fp "preflight" "$fp"
    # Installed: reports the upgrade path.
    inst; inst --preflight
    contains "upgrade path" "$OUT" "install would only replace the app bundle"
    contains "agent loaded" "$OUT" "loaded → would be reloaded"
    contains "recorded original" "$OUT" "Stage Manager: was bool true → restored on uninstall"
    contains "recorded hotkey" "$OUT" "hotkey 126: was absent → removed on uninstall"
}

# ------------------------------------------------------------------ runner --
tap() { # name function
    case "$1" in *"$FILTER"*) ;; *) return 0 ;; esac
    N=$((N + 1))
    local out rc
    out="$(
        setup_sandbox "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9\n' '-')"
        CUR_OK=1
        "$2"
        [ "$CUR_OK" = 1 ] && exit 0 || exit 1
    )"
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "ok $N - $1"
        [ -z "$out" ] || printf '%s\n' "$out"
    else
        echo "not ok $N - $1"
        printf '%s\n' "$out"
        FAILED=$((FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES
#   - $1"
    fi
}

echo "TAP version 13"
tap "1 clean install then uninstall leaves zero diff" t_clean_roundtrip
tap "2 install twice (upgrade) then uninstall restores originals" t_upgrade
tap "3 uninstall without install is a no-op" t_uninstall_without_install
tap "4 hotkey 125 already bound stays untouched" t_hotkey_preexisting
tap "5 Stage Manager absent/true/false/int/float/no-domain restored exactly" t_stage_manager_values
tap "6 failure injected at each install step rolls back to zero diff" t_failure_at_each_step
tap "7 pre-existing ~/.config/hyprmac is preserved" t_config_preexisting
tap "8 KEEP_CONFIG=1 keeps the config" t_keep_config
tap "9 changed ncprefs entry removed, other apps untouched" t_ncprefs_changed_entry
tap "10 user change to unrelated hotkey 118 survives uninstall" t_unrelated_hotkey_change
tap "11 --dry-run changes nothing (install and uninstall)" t_dry_run
tap "12 uninstall from the in-bundle script copy without the repo" t_uninstall_from_bundle
tap "13 sandbox guard refuses real command paths and the real HOME" t_sandbox_guard
tap "14 verify_rollback detects divergence" t_verify_detects_divergence
tap "15 pre-existing app data and app bundle are left/restored" t_preexisting_residue_and_app
tap "16 missing activateSettings warns about logout" t_no_activate_settings
tap "17 missing APP_SRC fails before any change" t_missing_app_src
tap "18 quit via SIGTERM (launchd or pkill), SIGKILL after 3 s, never Apple Events" t_quit_paths
tap "19 lsregister counts only the installed path; build copies ignored" t_lsregister_build_copies
tap "20 Stage Manager read-back, visibility note, no WindowManager restart" t_stage_manager_verify
tap "21 logs and crash reports: new ones removed, pre-existing restored" t_crash_reports
tap "22 make install/uninstall DRY_RUN=1 pass --dry-run; make preflight" t_make_dry_run
tap "23 --preflight is read-only and reports the planned changes" t_preflight
echo "1..$N"
if [ "$FAILED" -gt 0 ]; then
    echo "# FAILED $FAILED of $N:$FAILED_NAMES"
    exit 1
fi
echo "# all $N passed"
