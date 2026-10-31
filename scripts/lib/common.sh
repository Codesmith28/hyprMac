# shellcheck shell=bash
# Shared code for install.sh, uninstall.sh, snapshot.sh and verify_rollback.sh.
#
# Sourced relative to the calling script (scripts/lib/common.sh in the repo,
# Contents/Resources/scripts/lib/common.sh inside the app bundle), so nothing
# here may depend on the repository layout.
#
# Must stay compatible with macOS /bin/bash 3.2: no associative arrays, no
# mapfile, and empty arrays are expanded with ${a[@]+"${a[@]}"} under set -u.

# ---------------------------------------------------------------- constants --
BUNDLE_ID="dev.codesmith28.hyprmac"
APP_NAME="hyprMac"

# Every external command that touches system state goes through one of these
# variables so the sandbox tests can substitute shims.
: "${DEFAULTS:=/usr/bin/defaults}"
: "${PLUTIL:=/usr/bin/plutil}"
: "${LAUNCHCTL:=/bin/launchctl}"
: "${TCCUTIL:=/usr/bin/tccutil}"
: "${LSREGISTER:=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
: "${ACTIVATE_SETTINGS:=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings}"
: "${OPEN:=/usr/bin/open}"
: "${PKILL:=/usr/bin/pkill}"
: "${KILLALL:=/usr/bin/killall}"
: "${PYTHON:=/usr/bin/python3}"
: "${UID_VAL:=$(/usr/bin/id -u)}"
HYPR_CMD_VARS="DEFAULTS PLUTIL LAUNCHCTL TCCUTIL LSREGISTER ACTIVATE_SETTINGS OPEN PKILL KILLALL PYTHON"

# Runs after every change to com.apple.WindowManager (empty: nothing). We never
# restart WindowManager ourselves: that drops the user's window state.
: "${HYPR_WM_APPLY_CMD:=}"
# Optional probe: exit 0 when Stage Manager is still visually active. When
# empty, install assumes it is if it was enabled before the change, because
# WindowManager does not observe preference writes made with defaults.
: "${HYPR_WM_ACTIVE_CMD:=}"
WM_NOTE="Stage Manager change applies after logout or toggle in Control Center"
: "${KEEP_CONFIG:=0}"
: "${DRY_RUN:=0}"

APP_DEST="$HOME/Applications/$APP_NAME.app"
APP_BINARY="$APP_DEST/Contents/MacOS/$APP_NAME"
SUPPORT_DIR="$HOME/Library/Application Support/hyprMac"
STATE_DIR="$SUPPORT_DIR/install"
MANIFEST="$STATE_DIR/manifest"
BEFORE_SNAPSHOT="$STATE_DIR/before.snapshot"
BACKUP_DIR="$STATE_DIR/backups"
AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
AGENT_TARGET="gui/$UID_VAL/$BUNDLE_ID"
CONFIG_PARENT="$HOME/.config"
CONFIG_DIR="$CONFIG_PARENT/hyprmac"
_tmp_root="${TMPDIR:-/tmp}"
_tmp_root="${_tmp_root%/}"
# Where uninstall keeps before/after snapshots once the state dir is gone.
VERIFY_DIR="${HYPR_VERIFY_DIR:-$_tmp_root/hyprmac-verify-$UID_VAL}"

HOTKEY_DOMAIN="com.apple.symbolichotkeys"
WM_DOMAIN="com.apple.WindowManager"
WM_KEY="GloballyEnabled"
NC_DOMAIN="com.apple.ncprefs"
HOTKEY_IDS="125 126"
ACCESSIBILITY_URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

# Residue the app (or macOS on its behalf) creates at runtime. Uninstall
# deletes it, except paths that existed before install: those are backed up
# by install and restored exactly.
residue_fixed() {
    printf '%s\n' \
        "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
        "$HOME/Library/Caches/$BUNDLE_ID" \
        "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
        "$HOME/Library/Logs/$APP_NAME"
}
# Glob residue, one family per argument: httpstorages | crashreports.
residue_glob() {
    local p
    case "$1" in
        httpstorages) for p in "$HOME/Library/HTTPStorages/$BUNDLE_ID"*; do
                if [ -e "$p" ] || [ -L "$p" ]; then printf '%s\n' "$p"; fi; done ;;
        crashreports) for p in "$HOME/Library/Logs/DiagnosticReports/$APP_NAME-"*; do
                if [ -e "$p" ] || [ -L "$p" ]; then printf '%s\n' "$p"; fi; done ;;
    esac
}
RESIDUE_GLOBS="httpstorages crashreports"
residue_glob_label() {
    case "$1" in
        httpstorages) printf '%s*' "$(tilde "$HOME/Library/HTTPStorages/$BUNDLE_ID")" ;;
        crashreports) printf '%s-*' "$(tilde "$HOME/Library/Logs/DiagnosticReports/$APP_NAME")" ;;
    esac
}
residue_paths() {
    residue_fixed
    local g
    for g in $RESIDUE_GLOBS; do residue_glob "$g"; done
}

# ------------------------------------------------------------------ output --
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_DIM=; C_BOLD=; C_RESET=
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
title() { printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

is_dry() { [ "$DRY_RUN" = 1 ]; }

# Quote a command for display.
show_cmd() {
    local out="" a
    for a in "$@"; do out="$out $(printf '%q' "$a")"; done
    printf '%s' "${out# }"
}

# Run a state-changing command, or print it under --dry-run.
run() {
    if is_dry; then
        printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$(show_cmd "$@")"
        return 0
    fi
    # Echoed on stderr so redirecting a command's stdout keeps the trace.
    printf '%s  $ %s%s\n' "$C_DIM" "$(show_cmd "$@")" "$C_RESET" >&2
    "$@"
}

# Write $2 to file $1 (state-changing).
write_file() {
    if is_dry; then
        printf '%s[dry-run]%s write %s (%d bytes)\n' "$C_DIM" "$C_RESET" "$1" "${#2}"
        return 0
    fi
    printf '%s' "$2" >"$1"
}

# Append one action to the manifest (state-changing).
record() {
    if is_dry; then
        printf '%s[dry-run]%s record: %s\n' "$C_DIM" "$C_RESET" "$*"
        return 0
    fi
    printf '%s\n' "$*" >>"$MANIFEST"
}

# ------------------------------------------------------------------ safety --
# With HYPR_SANDBOX=1 every command variable must point at a shim, never at a
# real system binary, and HOME must not be the real home directory.
sandbox_guard() {
    case "$UID_VAL" in '' | *[!0-9]*) die "UID_VAL must be a number, got '$UID_VAL'" ;; esac
    [ "${HYPR_SANDBOX:-0}" = 1 ] || return 0
    local v val bad=0
    for v in $HYPR_CMD_VARS; do
        val="${!v}"
        case "$val" in
            /usr/* | /bin/* | /sbin/* | /System/* | /Library/* | /opt/* | /Applications/* | /private/var/db/*)
                err "HYPR_SANDBOX=1 but $v points at a real system path: $val"
                bad=1 ;;
            /*) ;;
            *)
                err "HYPR_SANDBOX=1 but $v is not an absolute path: '$val'"
                bad=1 ;;
        esac
    done
    local me real_home
    me="$(/usr/bin/id -un)"
    real_home="$(eval "printf '%s' ~$me")"
    if [ -z "$HOME" ] || [ "$HOME" = "$real_home" ] || [ "$HOME" = "/" ]; then
        err "HYPR_SANDBOX=1 but HOME is the real home directory ($HOME)"
        bad=1
    fi
    [ "$bad" = 0 ] || die "refusing to run: sandbox is not isolated"
}

# ------------------------------------------------------------- temp files --
HYPR_TMP=""
make_tmp() {
    if [ -z "$HYPR_TMP" ]; then
        HYPR_TMP="$(/usr/bin/mktemp -d "$_tmp_root/hyprmac.XXXXXX")"
    fi
}
cleanup_tmp() {
    if [ -n "$HYPR_TMP" ] && [ -d "$HYPR_TMP" ]; then rm -rf "$HYPR_TMP"; fi
    HYPR_TMP=""
}

# ----------------------------------------------------------- plist helpers --
# Canonical, type-preserving JSON of selected key paths of a plist file.
# argv: file keypath...   stdout: "<keypath>\t<json|absent>" per key path.
PY_CANON='
import json, plistlib, sys, datetime
def load(p):
    with open(p, "rb") as f:
        data = f.read()
    return plistlib.loads(data) if data.strip() else {}
def canon(v):
    if isinstance(v, bool): return v
    if isinstance(v, (int, float, str)): return v
    if isinstance(v, bytes): return {"$data": v.hex()}
    if isinstance(v, datetime.datetime): return {"$date": v.isoformat()}
    if isinstance(v, dict): return {str(k): canon(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)): return [canon(x) for x in v]
    return {"$repr": repr(v)}
root = load(sys.argv[1])
for kp in sys.argv[2:]:
    cur, found = root, True
    for part in kp.split("."):
        if isinstance(cur, dict) and part in cur: cur = cur[part]
        else: found = False; break
    out = json.dumps(canon(cur), sort_keys=True, separators=(",", ":")) if found else "absent"
    print(kp + "\t" + out)
'

# Does the ncprefs export have an entry for argv[2]?  stdout: present|absent
PY_NC_HAS='
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    data = f.read()
d = plistlib.loads(data) if data.strip() else {}
apps = d.get("apps") if isinstance(d, dict) else None
hit = isinstance(apps, list) and any(isinstance(a, dict) and a.get("bundle-id") == sys.argv[2] for a in apps)
print("present" if hit else "absent")
'

# Remove every entry with bundle-id argv[3] from the apps array of argv[1],
# writing argv[2] in the same format. stdout: changed|unchanged
PY_NC_FILTER='
import plistlib, sys
src, dst, bid = sys.argv[1:4]
with open(src, "rb") as f:
    data = f.read()
d = plistlib.loads(data) if data.strip() else {}
apps = d.get("apps") if isinstance(d, dict) else None
if not isinstance(apps, list):
    print("unchanged"); sys.exit(0)
kept = [a for a in apps if not (isinstance(a, dict) and a.get("bundle-id") == bid)]
if len(kept) == len(apps):
    print("unchanged"); sys.exit(0)
d["apps"] = kept
fmt = plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML
with open(dst, "wb") as f:
    plistlib.dump(d, f, fmt=fmt, sort_keys=False)
print("changed")
'

# Save the (first) apps entry for argv[3] and its index from export argv[1]
# into plist argv[2].
PY_NC_SAVE='
import plistlib, sys
src, dst, bid = sys.argv[1:4]
with open(src, "rb") as f:
    d = plistlib.load(f)
for i, a in enumerate(d.get("apps", [])):
    if isinstance(a, dict) and a.get("bundle-id") == bid:
        with open(dst, "wb") as f:
            plistlib.dump({"index": i, "entry": a}, f, fmt=plistlib.FMT_BINARY)
        break
'

# Put the saved entry argv[3] back into export argv[1] (replacing any current
# entries for its bundle id, at the original index), writing argv[2] in the
# same format. stdout: changed|unchanged
PY_NC_RESTORE='
import plistlib, sys
src, dst, saved = sys.argv[1:4]
with open(src, "rb") as f:
    data = f.read()
d = plistlib.loads(data) if data.strip() else {}
with open(saved, "rb") as f:
    s = plistlib.load(f)
entry, idx = s["entry"], s["index"]
bid = entry.get("bundle-id")
apps = d.get("apps") if isinstance(d.get("apps"), list) else []
kept = [a for a in apps if not (isinstance(a, dict) and a.get("bundle-id") == bid)]
kept.insert(min(idx, len(kept)), entry)
if kept == apps and "apps" in d:
    print("unchanged"); sys.exit(0)
d["apps"] = kept
fmt = plistlib.FMT_BINARY if data.startswith(b"bplist") or not data.strip() else plistlib.FMT_XML
with open(dst, "wb") as f:
    plistlib.dump(d, f, fmt=fmt, sort_keys=False)
print("changed")
'

# Number of top-level keys of a plist dict.
PY_DICT_LEN='
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    data = f.read()
d = plistlib.loads(data) if data.strip() else {}
print(len(d) if isinstance(d, dict) else -1)
'

py() { "$PYTHON" -I -c "$@"; }

# domain_export DOMAIN FILE  (read-only; also used under --dry-run)
domain_export() {
    "$DEFAULTS" export "$1" "$2" || { err "defaults export $1 failed"; return 1; }
}

# plist_has FILE KEYPATH
plist_has() { "$PLUTIL" -type "$2" "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------- snapshot --
tilde() {
    case "$1" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

sha_of_file() { /usr/bin/shasum -a 256 <"$1" | /usr/bin/cut -c1-64; }

# Deterministic content hash of a directory tree (paths, types, file modes,
# file contents, symlink targets; no timestamps).
tree_hash() {
    (
        cd "$1" || exit 1
        /usr/bin/find . -print | LC_ALL=C /usr/bin/sort | while IFS= read -r f; do
            if [ -L "$f" ]; then
                printf 'l %s -> %s\n' "$f" "$(/usr/bin/readlink "$f")"
            elif [ -d "$f" ]; then
                printf 'd %s\n' "$f"
            elif [ -f "$f" ]; then
                printf 'f %s %s %s\n' "$f" "$(/usr/bin/stat -f %Lp "$f")" "$(sha_of_file "$f")"
            else
                printf 'o %s\n' "$f"
            fi
        done
    ) | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64
}

# fp_path PATH content|type  -> one snapshot line
fp_path() {
    local p="$1" mode="$2" t
    t="$(tilde "$p")"
    if [ -L "$p" ]; then
        printf 'path %s symlink %s\n' "$t" "$(/usr/bin/readlink "$p")"
    elif [ -d "$p" ]; then
        if [ "$mode" = content ]; then printf 'path %s dir tree=%s\n' "$t" "$(tree_hash "$p")"
        else printf 'path %s dir\n' "$t"; fi
    elif [ -f "$p" ]; then
        if [ "$mode" = content ]; then printf 'path %s file sha256=%s\n' "$t" "$(sha_of_file "$p")"
        else printf 'path %s file\n' "$t"; fi
    elif [ -e "$p" ]; then
        printf 'path %s other\n' "$t"
    else
        printf 'path %s absent\n' "$t"
    fi
}

# Deterministic fingerprint of everything install may change. stdout.
take_snapshot() {
    local d
    d="$(/usr/bin/mktemp -d "$_tmp_root/hyprmac-snap.XXXXXX")" || return 1
    local rc=0
    _snapshot_lines "$d" | LC_ALL=C /usr/bin/sort || rc=1
    rm -rf "$d"
    return "$rc"
}

_snapshot_lines() {
    local d="$1" id kps="" kp line out nc n
    domain_export "$HOTKEY_DOMAIN" "$d/hk.plist" || return 1
    for id in $HOTKEY_IDS; do kps="$kps AppleSymbolicHotKeys.$id"; done
    # shellcheck disable=SC2086
    out="$(py "$PY_CANON" "$d/hk.plist" $kps)" || return 1
    while IFS=$'\t' read -r kp line; do
        printf 'hotkey %s %s\n' "${kp#AppleSymbolicHotKeys.}" "$line"
    done <<EOF
$out
EOF
    domain_export "$WM_DOMAIN" "$d/wm.plist" || return 1
    out="$(py "$PY_CANON" "$d/wm.plist" "$WM_KEY")" || return 1
    printf 'wm %s %s\n' "$WM_KEY" "${out#*$'\t'}"
    domain_export "$NC_DOMAIN" "$d/nc.plist" || return 1
    nc="$(py "$PY_NC_HAS" "$d/nc.plist" "$BUNDLE_ID")" || return 1
    printf 'ncprefs %s %s\n' "$BUNDLE_ID" "$nc"

    if "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
        printf 'launchagent %s loaded\n' "$BUNDLE_ID"
    else
        printf 'launchagent %s not-loaded\n' "$BUNDLE_ID"
    fi
    n="$(lsregister_records)"
    printf 'lsregister %s records=%s\n' "$(tilde "$APP_DEST")" "${n:-0}"

    # Files install writes: compare contents.
    fp_path "$APP_DEST" content
    fp_path "$AGENT_PLIST" content
    # Directories install may create, and runtime residue: existence + type.
    fp_path "$HOME/Applications" type
    fp_path "$HOME/Library/LaunchAgents" type
    fp_path "$SUPPORT_DIR" type
    fp_path "$STATE_DIR" type
    fp_path "$CONFIG_PARENT" type
    fp_path "$CONFIG_DIR" type
    local p g any
    while IFS= read -r p; do fp_path "$p" type; done <<EOF
$(residue_fixed)
EOF
    for g in $RESIDUE_GLOBS; do
        any=0
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            fp_path "$p" type
            any=1
        done <<EOF
$(residue_glob "$g")
EOF
        [ "$any" = 1 ] || printf 'path %s none\n' "$(residue_glob_label "$g")"
    done
}

# Number of LaunchServices records whose path is exactly the installed bundle
# (build copies registered by Spotlight/Finder are ignored). Records look like
# "path:                       /Users/me/Applications/hyprMac.app (0x1b88)".
lsregister_records() {
    { "$LSREGISTER" -dump 2>/dev/null || true; } | /usr/bin/awk -v want="$APP_DEST" '
        /^path:/ {
            p = $0
            sub(/^path:[ \t]+/, "", p)
            sub(/ \(0x[0-9A-Fa-f]+\)$/, "", p)
            if (p == want) n++
        }
        END { print n + 0 }'
}

# verify_snapshots BEFORE AFTER -> 0 when identical (modulo KEEP_CONFIG).
verify_snapshots() {
    local before="$1" after="$2" filter='^$'
    [ -f "$before" ] || { err "missing snapshot: $before"; return 2; }
    [ -f "$after" ] || { err "missing snapshot: $after"; return 2; }
    if [ "$KEEP_CONFIG" = 1 ]; then filter='^path ~/\.config( |/hyprmac )'; fi
    local diffout rc=0
    diffout="$(/usr/bin/diff -u \
        <(/usr/bin/grep -Ev "$filter" "$before" || true) \
        <(/usr/bin/grep -Ev "$filter" "$after" || true))" || rc=$?
    if [ "$rc" = 0 ]; then
        ok "rollback verified: system state matches the pre-install snapshot"
        return 0
    fi
    err "rollback verification FAILED: state differs from the pre-install snapshot"
    printf '%s\n' "$diffout" | /usr/bin/sed -e "1s|.*|--- before ($before)|" -e "2s|.*|+++ after ($after)|" >&2
    return 1
}

# ------------------------------------------------------------- app process --
app_running() { "$PKILL" -0 -x "$APP_NAME" >/dev/null 2>&1; }

# Stop the app with signals only (no Apple Events, so no Automation/TCC
# prompt): SIGTERM through launchd when the agent is loaded, else pkill; the
# app quits cleanly on SIGTERM. After 3 s, SIGKILL.
quit_app() {
    if is_dry; then
        printf '%s[dry-run]%s stop %s: %s, else %s; SIGKILL after 3 s\n' "$C_DIM" "$C_RESET" "$APP_NAME" \
            "$(show_cmd "$LAUNCHCTL" kill SIGTERM "$AGENT_TARGET")" "$(show_cmd "$PKILL" -TERM -x "$APP_NAME")"
        return 0
    fi
    app_running || return 0
    info "stopping $APP_NAME (SIGTERM)"
    local sent=0
    if "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
        if run "$LAUNCHCTL" kill SIGTERM "$AGENT_TARGET" >/dev/null 2>&1; then sent=1; fi
    fi
    # Not started by launchd (or launchd had no process): signal it directly.
    if [ "$sent" = 0 ]; then run "$PKILL" -TERM -x "$APP_NAME" || true; fi
    local i=0
    while [ "$i" -lt 30 ]; do
        app_running || return 0
        sleep 0.1
        i=$((i + 1))
    done
    warn "$APP_NAME did not exit within 3 s; sending SIGKILL"
    run "$PKILL" -KILL -x "$APP_NAME" || true
}

# ---------------------------------------------------- settings application --
activate_hotkeys() {
    if [ -x "$ACTIVATE_SETTINGS" ]; then
        run "$ACTIVATE_SETTINGS" -u || warn "activateSettings failed; log out and back in to apply ⌥8/⌥9"
    else
        warn "activateSettings not found; log out and back in for the keyboard shortcut change to apply"
    fi
}

# Is a recorded original value ("bool true", "integer 1", ...) enabled?
wm_spec_enabled() {
    case "$1" in
        "bool true" | "bool 1" | "bool YES") return 0 ;;
        integer\ 0 | float\ 0 | float\ 0.0 | absent | bool\ *) return 1 ;;
        integer\ * | float\ *) return 0 ;;
        string\ 1 | string\ true | string\ YES | string\ yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Should we tell the user the Stage Manager change is not visible yet?
# $1: the value Stage Manager had before the change (manifest spec).
wm_maybe_still_active() {
    if [ -n "$HYPR_WM_ACTIVE_CMD" ]; then
        /bin/sh -c "$HYPR_WM_ACTIVE_CMD" >/dev/null 2>&1
        return $?
    fi
    wm_spec_enabled "$1"
}

wm_apply() {
    if [ -n "$HYPR_WM_APPLY_CMD" ]; then
        run /bin/sh -c "$HYPR_WM_APPLY_CMD" || warn "HYPR_WM_APPLY_CMD failed"
    fi
}

# ---------------------------------------------------------------- manifest --
MANIFEST_LINES=()
load_manifest() {
    MANIFEST_LINES=()
    local l
    while IFS= read -r l || [ -n "$l" ]; do
        MANIFEST_LINES+=("$l")
    done <"$MANIFEST"
}

# manifest_has "exact line"
manifest_has() {
    local l
    for l in ${MANIFEST_LINES[@]+"${MANIFEST_LINES[@]}"}; do
        [ "$l" = "$1" ] && return 0
    done
    return 1
}

# --------------------------------------------------------------- undo ops --
# Every undo is idempotent and reports failure through its return status.
# They run in "if" context (set -e is suspended), so every step checks errors.

undo_hotkey_absent() { # id
    local id="$1" f
    make_tmp
    f="$HYPR_TMP/hk-undo-$id.plist"
    domain_export "$HOTKEY_DOMAIN" "$f" || return 1
    if ! plist_has "$f" "AppleSymbolicHotKeys.$id"; then return 0; fi
    "$PLUTIL" -remove "AppleSymbolicHotKeys.$id" "$f" >/dev/null || return 1
    run "$DEFAULTS" import "$HOTKEY_DOMAIN" "$f" || return 1
    NEED_ACTIVATE=1
}

undo_hotkeys_dict_created() {
    local f
    make_tmp
    f="$HYPR_TMP/hk-undo-dict.plist"
    domain_export "$HOTKEY_DOMAIN" "$f" || return 1
    plist_has "$f" AppleSymbolicHotKeys || return 0
    [ -z "$("$PLUTIL" -extract AppleSymbolicHotKeys raw "$f")" ] || return 0
    "$PLUTIL" -remove AppleSymbolicHotKeys "$f" >/dev/null || return 1
    run "$DEFAULTS" import "$HOTKEY_DOMAIN" "$f" || return 1
    NEED_ACTIVATE=1
}

undo_wm() { # "absent" | "<type> <value>"
    local spec="$1" type value f
    type="${spec%% *}"
    value="${spec#* }"
    make_tmp
    f="$HYPR_TMP/wm-undo.plist"
    case "$type" in
        absent)
            domain_export "$WM_DOMAIN" "$f" || return 1
            plist_has "$f" "$WM_KEY" || return 0
            run "$DEFAULTS" delete "$WM_DOMAIN" "$WM_KEY" || return 1 ;;
        bool) run "$DEFAULTS" write "$WM_DOMAIN" "$WM_KEY" -bool "$value" || return 1 ;;
        integer) run "$DEFAULTS" write "$WM_DOMAIN" "$WM_KEY" -int "$value" || return 1 ;;
        float) run "$DEFAULTS" write "$WM_DOMAIN" "$WM_KEY" -float "$value" || return 1 ;;
        string) run "$DEFAULTS" write "$WM_DOMAIN" "$WM_KEY" -string "$value" || return 1 ;;
        *) err "cannot restore $WM_DOMAIN $WM_KEY of type '$type'"; return 1 ;;
    esac
    wm_apply
    if [ "$type" != absent ] && wm_spec_enabled "$spec"; then
        info "Stage Manager restored to enabled. $WM_NOTE."
    fi
}

undo_wm_domain_absent() {
    local f n
    make_tmp
    f="$HYPR_TMP/wm-undo-domain.plist"
    domain_export "$WM_DOMAIN" "$f" || return 1
    n="$(py "$PY_DICT_LEN" "$f")" || return 1
    if [ "$n" = 0 ]; then
        run "$DEFAULTS" delete "$WM_DOMAIN" >/dev/null 2>&1 || true
    fi
}

undo_dir_created() { # path
    local p="$1"
    [ -d "$p" ] || return 0
    if [ "$p" = "$STATE_DIR" ]; then
        run rm -rf "$p" || return 1
        return 0
    fi
    if [ -n "$(/bin/ls -A "$p" 2>/dev/null)" ]; then
        if [ "$KEEP_CONFIG" = 1 ] && [ "$p" = "$CONFIG_PARENT" ]; then return 0; fi
        warn "not removing $(tilde "$p"): it is not empty"
        return 0
    fi
    run rmdir "$p" || return 1
}

undo_backup() { # "name path"
    local name="${1%% *}" path="${1#* }"
    [ -e "$BACKUP_DIR/$name" ] || [ -L "$BACKUP_DIR/$name" ] || return 0
    if [ -e "$path" ] || [ -L "$path" ]; then run rm -rf "$path" || return 1; fi
    run mv "$BACKUP_DIR/$name" "$path" || return 1
}

undo_action() { # action rest
    local action="$1" rest="$2"
    case "$action" in
        '' | '#'*) return 0 ;;
        dir_created) undo_dir_created "$rest" ;;
        file_created | app_installed)
            if [ -e "$rest" ] || [ -L "$rest" ]; then run rm -rf "$rest" || return 1; fi ;;
        backup) undo_backup "$rest" ;;
        lsregister) run "$LSREGISTER" -u "$rest" || warn "lsregister -u failed (ignored)" ;;
        hotkey)
            case "${rest#* }" in
                absent) undo_hotkey_absent "${rest%% *}" ;;
                untouched) return 0 ;;
                *) err "unknown hotkey record: $rest"; return 1 ;;
            esac ;;
        hotkeys_dict_created) undo_hotkeys_dict_created ;;
        wm_globally_enabled) undo_wm "$rest" ;;
        wm_domain_absent) undo_wm_domain_absent ;;
        launchagent_loaded)
            local out
            if is_dry; then run "$LAUNCHCTL" bootout "$AGENT_TARGET"; return 0; fi
            if "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
                printf '%s  $ %s%s\n' "$C_DIM" "$(show_cmd "$LAUNCHCTL" bootout "$AGENT_TARGET")" "$C_RESET" >&2
                out="$("$LAUNCHCTL" bootout "$AGENT_TARGET" 2>&1)" || {
                    case "$out" in
                        *"No such process"* | *"not loaded"* | *"Could not find"*) ;;
                        *) err "launchctl bootout failed: $out"; return 1 ;;
                    esac
                }
            fi ;;
        tcc_reset) run "$TCCUTIL" reset Accessibility "$BUNDLE_ID" >/dev/null || warn "tccutil reset failed (ignored)" ;;
        config_dir_created)
            if [ "$KEEP_CONFIG" = 1 ]; then
                info "KEEP_CONFIG=1: keeping $(tilde "$rest")"
                return 0
            fi
            if [ -e "$rest" ]; then run rm -rf "$rest" || return 1; fi ;;
        prefs_backup)
            [ -f "$BACKUP_DIR/prefs.plist" ] || return 0
            if ! is_dry; then "$DEFAULTS" delete "$BUNDLE_ID" >/dev/null 2>&1 || true; fi
            run "$DEFAULTS" import "$BUNDLE_ID" "$BACKUP_DIR/prefs.plist" || return 1 ;;
        ncprefs_preexisting) restore_ncprefs ;;
        config_dir_preexisting | residue_preexisting | install_version) return 0 ;;
        *) warn "unknown manifest action '$action' (ignored)" ;;
    esac
}

# --------------------------------------------------------------- residue --
clean_ncprefs() {
    local f out result
    make_tmp
    f="$HYPR_TMP/nc.plist"
    out="$HYPR_TMP/nc-filtered.plist"
    domain_export "$NC_DOMAIN" "$f" || return 1
    result="$(py "$PY_NC_FILTER" "$f" "$out" "$BUNDLE_ID")" || return 1
    if [ "$result" = changed ]; then
        run "$DEFAULTS" import "$NC_DOMAIN" "$out" || return 1
        run "$KILLALL" usernoted >/dev/null 2>&1 || true
    fi
}

restore_ncprefs() {
    local saved="$BACKUP_DIR/ncprefs-entry.plist" f out result
    [ -f "$saved" ] || return 0
    make_tmp
    f="$HYPR_TMP/nc-restore.plist"
    out="$HYPR_TMP/nc-restored.plist"
    domain_export "$NC_DOMAIN" "$f" || return 1
    result="$(py "$PY_NC_RESTORE" "$f" "$out" "$saved")" || return 1
    if [ "$result" = changed ]; then
        run "$DEFAULTS" import "$NC_DOMAIN" "$out" || return 1
        run "$KILLALL" usernoted >/dev/null 2>&1 || true
    fi
}

clean_residue() {
    local p failed=0
    if ! manifest_has "residue_preexisting $HOME/Library/Preferences/$BUNDLE_ID.plist"; then
        if is_dry; then run "$DEFAULTS" delete "$BUNDLE_ID"
        else "$DEFAULTS" delete "$BUNDLE_ID" >/dev/null 2>&1 || true; fi
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        manifest_has "residue_preexisting $p" && continue
        if [ -e "$p" ] || [ -L "$p" ]; then run rm -rf "$p" || failed=1; fi
    done <<EOF
$(residue_paths)
EOF
    if ! manifest_has "ncprefs_preexisting 1"; then clean_ncprefs || failed=1; fi
    return "$failed"
}

# ------------------------------------------------------------- uninstall --
# do_uninstall [rollback]: undo everything recorded in the manifest, clean
# residue, then verify against before.snapshot. Returns non-zero on failure.
do_uninstall() {
    local mode="${1:-uninstall}" failures=0 i action rest line
    NEED_ACTIVATE=0
    if [ ! -f "$MANIFEST" ]; then
        info "no install manifest found at $(tilde "$MANIFEST"); nothing to undo"
        return 0
    fi
    load_manifest
    quit_app

    local have_before=0
    if [ -f "$BEFORE_SNAPSHOT" ]; then
        have_before=1
        if ! is_dry; then
            mkdir -p "$VERIFY_DIR"
            cp "$BEFORE_SNAPSHOT" "$VERIFY_DIR/before.snapshot"
            rm -f "$VERIFY_DIR/after.snapshot"
        fi
    fi

    title "removing app residue"
    clean_residue || failures=$((failures + 1))

    title "undoing recorded install actions"
    i=$((${#MANIFEST_LINES[@]} - 1))
    while [ "$i" -ge 0 ]; do
        line="${MANIFEST_LINES[$i]}"
        action="${line%% *}"
        rest=""
        [ "$action" = "$line" ] || rest="${line#* }"
        if ! undo_action "$action" "$rest"; then
            err "failed to undo: $line"
            failures=$((failures + 1))
        fi
        i=$((i - 1))
    done
    if [ "$NEED_ACTIVATE" = 1 ]; then activate_hotkeys; fi
    cleanup_tmp

    if is_dry; then
        info "dry run: nothing was changed"
        return 0
    fi
    if [ "$failures" -gt 0 ]; then
        err "$failures undo step(s) failed; state kept in $(tilde "$STATE_DIR") if present"
    fi
    if [ "$have_before" = 1 ]; then
        take_snapshot >"$VERIFY_DIR/after.snapshot" || { err "could not take after-snapshot"; return 1; }
        if ! verify_snapshots "$VERIFY_DIR/before.snapshot" "$VERIFY_DIR/after.snapshot"; then
            return 1
        fi
    else
        warn "no before.snapshot recorded; skipping rollback verification"
    fi
    [ "$failures" = 0 ] || return 1
    if [ "$mode" = rollback ]; then ok "install rolled back"; else ok "hyprMac uninstalled"; fi
}
