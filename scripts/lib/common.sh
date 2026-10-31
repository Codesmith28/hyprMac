# shellcheck shell=bash
# Shared code for install.sh, uninstall.sh, snapshot.sh and verify_rollback.sh.
#
# Sourced relative to the calling script (scripts/lib/common.sh in the repo,
# Contents/Resources/scripts/lib/common.sh inside the app bundle), so nothing
# here may depend on the repository layout.
#
# Must stay compatible with macOS /bin/bash 3.2: no associative arrays, no
# mapfile, and empty arrays are expanded with ${a[@]+"${a[@]}"} under set -u.
#
# Safety model (see the rollback review):
#   * The manifest only says WHICH fixed undo to run. Every destructive undo
#     acts on a compiled-in path; the few path arguments (residue backups) are
#     checked against an allowlist. Lines end in " ;" so torn writes are
#     detected, and the whole manifest is validated before anything is undone.
#   * Undo progress is journaled, so an interrupted uninstall can be re-run.
#   * State and backups are never deleted unless every undo succeeded, and are
#     only discarded after the rollback verified.

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
# 1: reset the Accessibility grant even when hyprMac was used before; 0: never.
: "${HYPR_TCC_RESET:=}"

APP_DEST="$HOME/Applications/$APP_NAME.app"
APP_BINARY="$APP_DEST/Contents/MacOS/$APP_NAME"
APPSUPPORT_DIR="$HOME/Library/Application Support"
SUPPORT_DIR="$APPSUPPORT_DIR/hyprMac"
STATE_DIR="$SUPPORT_DIR/install"
MANIFEST="$STATE_DIR/manifest"
JOURNAL="$STATE_DIR/undone"
BEFORE_SNAPSHOT="$STATE_DIR/before.snapshot"
BACKUP_DIR="$STATE_DIR/backups"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/$BUNDLE_ID.plist"
AGENT_TARGET="gui/$UID_VAL/$BUNDLE_ID"
CONFIG_PARENT="$HOME/.config"
CONFIG_DIR="$CONFIG_PARENT/hyprmac"
# Verification snapshots (and, after a failed verification, the old state)
# live next to the state dir. The snapshot never looks inside it.
VERIFY_DIR="$APPSUPPORT_DIR/hyprMac-verify"
VERIFY_FAILED="$VERIFY_DIR/FAILED"
_tmp_root="${TMPDIR:-/tmp}"
_tmp_root="${_tmp_root%/}"
MANIFEST_HEADER="hyprmac-manifest 2"

HOTKEY_DOMAIN="com.apple.symbolichotkeys"
WM_DOMAIN="com.apple.WindowManager"
WM_KEY="GloballyEnabled"
NC_DOMAIN="com.apple.ncprefs"
HOTKEY_IDS="125 126"
ACCESSIBILITY_URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

# Directories install may create, by manifest key. Nothing else is ever
# created or removed as a directory. ~/Library/Application Support must exist.
dir_for_key() {
    case "$1" in
        support) printf '%s' "$SUPPORT_DIR" ;;
        state) printf '%s' "$STATE_DIR" ;;
        applications) printf '%s' "$HOME/Applications" ;;
        launchagents) printf '%s' "$AGENT_DIR" ;;
        dotconfig) printf '%s' "$CONFIG_PARENT" ;;
        *) return 1 ;;
    esac
}
key_for_dir() {
    case "$1" in
        "$SUPPORT_DIR") printf support ;;
        "$STATE_DIR") printf state ;;
        "$HOME/Applications") printf applications ;;
        "$AGENT_DIR") printf launchagents ;;
        "$CONFIG_PARENT") printf dotconfig ;;
        *) return 1 ;;
    esac
}

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

# Is $1 one of the residue paths uninstall may delete or restore? (allowlist)
is_residue_path() {
    local p="$1" f rest
    case "$p" in *$'\n'* | */../* | */.. | */./* | */.) return 1 ;; esac
    while IFS= read -r f; do
        [ "$p" = "$f" ] && return 0
    done <<EOF
$(residue_fixed)
EOF
    case "$p" in
        "$HOME/Library/HTTPStorages/$BUNDLE_ID"*)
            rest="${p#"$HOME/Library/HTTPStorages/"}" ;;
        "$HOME/Library/Logs/DiagnosticReports/$APP_NAME-"?*)
            rest="${p#"$HOME/Library/Logs/DiagnosticReports/"}" ;;
        *) return 1 ;;
    esac
    case "$rest" in */* | '') return 1 ;; esac
    return 0
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

# Append one action to the manifest (state-changing). Lines end in " ;" so a
# torn append is detectable.
record() {
    case "$*" in *$'\n'*) err "refusing to record a multi-line manifest entry"; return 1 ;; esac
    if is_dry; then
        printf '%s[dry-run]%s record: %s\n' "$C_DIM" "$C_RESET" "$*"
        return 0
    fi
    printf '%s ;\n' "$*" >>"$MANIFEST"
}

# ------------------------------------------------------------------ safety --
# Canonical absolute path (symlinks resolved). Fails when it does not exist.
canon() { /bin/realpath "$1" 2>/dev/null; }
dev_inode() { /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null; }

# Always: refuse root, a missing/empty HOME and HOME=/.
# With HYPR_SANDBOX=1 additionally require HYPR_SANDBOX_ROOT: HOME and every
# command variable must resolve (canonically, following symlinks) inside it,
# HOME must not be the real home (compared by device:inode), and the root may
# not contain the real home.
sandbox_guard() {
    case "$UID_VAL" in '' | *[!0-9]*) die "UID_VAL must be a number, got '$UID_VAL'" ;; esac
    if [ "$(/usr/bin/id -u)" = 0 ] || [ "$UID_VAL" = 0 ]; then
        die "do not run hyprMac's installer as root (no sudo): it installs for your user only"
    fi
    [ -n "${HOME:-}" ] || die "HOME is empty"
    local home_c
    home_c="$(canon "$HOME")" || die "HOME does not exist: $HOME"
    [ -d "$home_c" ] || die "HOME is not a directory: $HOME"
    [ "$home_c" != / ] || die "refusing to run with HOME=/"

    [ "${HYPR_SANDBOX:-0}" = 1 ] || return 0

    local bad=0 root_c real_home real_c v val val_c me
    if [ -z "${HYPR_SANDBOX_ROOT:-}" ] || ! root_c="$(canon "$HYPR_SANDBOX_ROOT")" || [ ! -d "$root_c" ]; then
        die "HYPR_SANDBOX=1 needs HYPR_SANDBOX_ROOT set to an existing directory"
    fi
    me="$(/usr/bin/id -un)"
    real_home="$(eval "printf '%s' ~$me")"
    real_c="$(canon "$real_home")" || real_c="$real_home"
    case "$root_c" in
        / | /private | /Users | /System* | /usr* | /bin* | /sbin* | /Library* | /Applications* | /opt*)
            err "HYPR_SANDBOX_ROOT is not a private directory: $root_c"; bad=1 ;;
    esac
    case "$real_c/" in "$root_c"/*)
        err "HYPR_SANDBOX_ROOT ($root_c) contains the real home ($real_c)"; bad=1 ;;
    esac
    case "$home_c/" in "$root_c"/*) ;; *)
        err "HYPR_SANDBOX=1 but HOME ($home_c) is not inside HYPR_SANDBOX_ROOT ($root_c)"; bad=1 ;;
    esac
    if [ "$(dev_inode "$home_c")" = "$(dev_inode "$real_c")" ]; then
        err "HYPR_SANDBOX=1 but HOME is the real home directory ($HOME)"; bad=1
    fi
    for v in $HYPR_CMD_VARS; do
        val="${!v}"
        case "$val" in /*) ;; *) err "HYPR_SANDBOX=1 but $v is not an absolute path: '$val'"; bad=1; continue ;; esac
        # A command may be missing (tests simulate that); its directory must exist.
        if ! val_c="$(canon "$val")"; then
            val_c="$(canon "$(dirname "$val")")/$(basename "$val")" || {
                err "HYPR_SANDBOX=1 but $v has no existing directory: $val"; bad=1; continue; }
        fi
        case "$val_c" in "$root_c"/*) ;; *)
            err "HYPR_SANDBOX=1 but $v points at a real system path: $val (resolves to $val_c)"; bad=1 ;;
        esac
    done
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
# PY_TOOL: embedded plist helper (pure file processing; see the commands below).
read -r -d '' PY_TOOL <<'PYEOF' || true
# plisttool.py: plist helpers for the hyprMac install scripts.
#
# Always run as `python3 -I plisttool.py <command> ...` (isolated mode). Pure
# file/stdin processing: it never touches preferences or any system state; the
# shell scripts do all reads and writes through `defaults`.
import base64
import datetime
import hashlib
import json
import os
import plistlib
import re
import sys


def load(path):
    if path == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(path, "rb") as f:
            data = f.read()
    if not data.strip():
        return {}
    d = plistlib.loads(data)
    return d


def dump(path, value):
    with open(path, "wb") as f:
        plistlib.dump(value, f, fmt=plistlib.FMT_BINARY, sort_keys=True)


def canon(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float, str)):
        return v
    if isinstance(v, bytes):
        return {"$data": v.hex()}
    if isinstance(v, datetime.datetime):
        return {"$date": v.isoformat()}
    if isinstance(v, dict):
        return {str(k): canon(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [canon(x) for x in v]
    if isinstance(v, plistlib.UID):
        return {"$uid": v.data}
    return {"$repr": repr(v)}


def cj(v):
    return json.dumps(canon(v), sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(v):
    return hashlib.sha256(cj(v).encode("utf-8")).hexdigest()[:16]


def walk(root, keypath):
    cur = root
    for part in keypath.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return False, None
    return True, cur


def hotkeys(d):
    hk = d.get("AppleSymbolicHotKeys") if isinstance(d, dict) else None
    return hk if isinstance(hk, dict) else None


def nc_apps(d):
    apps = d.get("apps") if isinstance(d, dict) else None
    return apps if isinstance(apps, list) else None


def is_ours(entry, bid):
    return isinstance(entry, dict) and entry.get("bundle-id") == bid


def xml_fragment(value):
    doc = plistlib.dumps(value, fmt=plistlib.FMT_XML).decode("utf-8")
    m = re.search(r"<plist[^>]*>\s*(.*?)\s*</plist>", doc, re.S)
    frag = m.group(1)
    return re.sub(r">\s+<", "><", frag)


def main(argv):
    cmd, a = argv[1], argv[2:]

    if cmd == "get":  # FILE KEYPATH -> canonical JSON | absent
        found, v = walk(load(a[0]), a[1])
        print(cj(v) if found else "absent")

    elif cmd == "dict_len":  # FILE
        d = load(a[0])
        print(len(d) if isinstance(d, dict) else -1)

    elif cmd == "type":  # FILE KEY -> bool|integer|float|string|other|absent
        d = load(a[0])
        if a[1] not in d:
            print("absent")
        else:
            v = d[a[1]]
            print("bool" if isinstance(v, bool) else "integer" if isinstance(v, int)
                  else "float" if isinstance(v, float) else "string" if isinstance(v, str) else "other")

    elif cmd == "hk_state":  # FILE ID -> absent | enabled | disabled
        hk = hotkeys(load(a[0]))
        if hk is None or a[1] not in hk:
            print("absent")
        else:
            v = hk[a[1]]
            print("enabled" if isinstance(v, dict) and v.get("enabled") == 1 else "disabled")

    elif cmd == "hk_dict":  # FILE -> absent | empty | present
        hk = hotkeys(load(a[0]))
        print("absent" if hk is None else "empty" if not hk else "present")

    elif cmd == "hk_b64":  # FILE ID -> base64(binary plist of the value)
        found, v = walk(load(a[0]), "AppleSymbolicHotKeys." + a[1])
        if not found:
            sys.exit("no such hotkey")
        print(base64.b64encode(plistlib.dumps(v, fmt=plistlib.FMT_BINARY)).decode("ascii"))

    elif cmd == "b64_xml":  # B64 -> compact XML fragment for `defaults write -dict-add`
        print(xml_fragment(plistlib.loads(base64.b64decode(a[0], validate=True))))

    elif cmd == "b64_json":  # B64 -> canonical JSON
        print(cj(plistlib.loads(base64.b64decode(a[0], validate=True))))

    elif cmd == "hk_remove":  # SRC DST ID -> writes {"AppleSymbolicHotKeys": without ID}
        hk = hotkeys(load(a[0]))
        if hk is None or a[2] not in hk:
            print("unchanged")
            return
        hk = dict(hk)
        del hk[a[2]]
        dump(a[1], {"AppleSymbolicHotKeys": hk})
        print("changed")

    elif cmd == "nc_has":  # FILE BID -> present | absent
        apps = nc_apps(load(a[0]))
        print("present" if apps and any(is_ours(x, a[1]) for x in apps) else "absent")

    elif cmd == "nc_filter":  # SRC DST BID -> writes {"apps": without BID}
        apps = nc_apps(load(a[0]))
        if apps is None:
            print("unchanged")
            return
        kept = [x for x in apps if not is_ours(x, a[2])]
        if len(kept) == len(apps):
            print("unchanged")
            return
        dump(a[1], {"apps": kept})
        print("changed")

    elif cmd == "nc_save":  # SRC DST BID -> saves {index, entry} of the first entry
        for i, x in enumerate(nc_apps(load(a[0])) or []):
            if is_ours(x, a[2]):
                dump(a[1], {"index": i, "entry": x})
                return
        sys.exit("no entry to save")

    elif cmd == "nc_restore":  # SRC DST SAVED -> writes {"apps": with the saved entry back in place}
        s = load(a[2])
        entry, idx = s["entry"], s["index"]
        apps = nc_apps(load(a[0])) or []
        kept = [x for x in apps if not is_ours(x, entry.get("bundle-id"))]
        kept.insert(min(idx, len(kept)), entry)
        if cj(kept) == cj(apps):
            print("unchanged")
            return
        dump(a[1], {"apps": kept})
        print("changed")

    elif cmd == "check_import":  # BEFORE EDIT AFTER: AFTER == BEFORE with EDIT's top-level keys merged in
        before, edit, after = load(a[0]), load(a[1]), load(a[2])
        expected = dict(before)
        expected.update(edit)
        bad = sorted(k for k in set(expected) | set(after)
                     if cj(expected.get(k, "<absent>")) != cj(after.get(k, "<absent>")))
        if bad:
            print("unexpected values after import for: " + ", ".join(bad))
            sys.exit(1)

    elif cmd == "same":  # A B -> exit 0 when canonically equal
        sys.exit(0 if cj(load(a[0])) == cj(load(a[1])) else 1)

    elif cmd == "extra_keys":  # CURRENT BACKUP -> top-level keys only in CURRENT
        cur, bak = load(a[0]), load(a[1])
        for k in sorted(set(cur) - set(bak)):
            print(k)

    elif cmd == "snap":  # HK WM NC BID HOTKEY_IDS... -> hard + soft snapshot lines
        hk_doc, wm_doc, nc_doc, bid = load(a[0]), load(a[1]), load(a[2]), a[3]
        ours = a[4:]
        out = []
        out.append("domain com.apple.symbolichotkeys %s" % ("present" if hk_doc else "absent"))
        hk = hotkeys(hk_doc)
        out.append("hotkeys-dict %s" % ("absent" if hk is None else "empty" if not hk else "present"))
        for i in ours:
            out.append("hotkey %s %s" % (i, cj(hk[i]) if hk is not None and i in hk else "absent"))
        for k, v in (hk or {}).items():
            if k not in ours:
                out.append("soft hotkey %s %s" % (k, cj(v)))
        for k, v in hk_doc.items():
            if k != "AppleSymbolicHotKeys":
                out.append("soft symbolichotkeys %s sha=%s" % (k, sha(v)))
        out.append("domain com.apple.WindowManager %s" % ("present" if wm_doc else "absent"))
        out.append("wm GloballyEnabled %s" % (cj(wm_doc["GloballyEnabled"]) if "GloballyEnabled" in wm_doc else "absent"))
        for k, v in wm_doc.items():
            if k != "GloballyEnabled":
                out.append("soft wm %s %s" % (k, cj(v)))
        apps = nc_apps(nc_doc)
        out.append("ncprefs %s %s" % (bid, "present" if apps and any(is_ours(x, bid) for x in apps) else "absent"))
        seen = {}
        for x in apps or []:
            if is_ours(x, bid):
                continue
            name = x.get("bundle-id", "?") if isinstance(x, dict) else "?"
            seen[name] = seen.get(name, 0) + 1
            out.append("soft ncprefs app %s#%d sha=%s" % (name, seen[name], sha(x)))
        for k, v in nc_doc.items():
            if k != "apps":
                out.append("soft ncprefs %s sha=%s" % (k, sha(v)))
        out.append("soft ncprefs domain %s" % ("present" if nc_doc else "absent"))
        for line in out:
            print(line)

    else:
        sys.exit("plisttool: unknown command " + cmd)


if __name__ == "__main__":
    main(sys.argv)
PYEOF

# pt COMMAND ARGS...: run the embedded plist helper.
pt() { "$PYTHON" -I -c "$PY_TOOL" "$@"; }

# domain_export DOMAIN FILE  (read-only; also used under --dry-run)
domain_export() {
    "$DEFAULTS" export "$1" "$2" || { err "defaults export $1 failed"; return 1; }
}

# plist_has FILE KEYPATH
plist_has() { "$PLUTIL" -type "$2" "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- snapshot --
tilde() {
    case "$1" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

sha_of_file() {
    local s
    s="$(/usr/bin/shasum -a 256 <"$1")" || return 1
    printf '%s' "${s%% *}"
}

# Deterministic content hash of a directory tree (paths, types, file modes,
# file contents, symlink targets; no timestamps).
tree_hash() {
    local list f line out=""
    list="$(cd "$1" && /usr/bin/find . -print | LC_ALL=C /usr/bin/sort)" || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -L "$1/$f" ]; then
            line="l $f -> $(/usr/bin/readlink "$1/$f")" || return 1
        elif [ -d "$1/$f" ]; then
            line="d $f"
        elif [ -f "$1/$f" ]; then
            line="f $f $(/usr/bin/stat -f %Lp "$1/$f") $(sha_of_file "$1/$f")" || return 1
        else
            line="o $f"
        fi
        out="$out$line"$'\n'
    done <<EOF
$list
EOF
    out="$(printf '%s' "$out" | /usr/bin/shasum -a 256)" || return 1
    printf '%s' "${out%% *}"
}

# fp_path PATH content|type  -> one snapshot line
fp_path() {
    local p="$1" mode="$2" t h
    t="$(tilde "$p")"
    if [ -L "$p" ]; then
        printf 'path %s symlink %s\n' "$t" "$(/usr/bin/readlink "$p")"
    elif [ -d "$p" ]; then
        if [ "$mode" = content ]; then
            h="$(tree_hash "$p")" || return 1
            printf 'path %s dir tree=%s\n' "$t" "$h"
        else printf 'path %s dir\n' "$t"; fi
    elif [ -f "$p" ]; then
        if [ "$mode" = content ]; then
            h="$(sha_of_file "$p")" || return 1
            printf 'path %s file sha256=%s\n' "$t" "$h"
        else printf 'path %s file\n' "$t"; fi
    elif [ -e "$p" ]; then
        printf 'path %s other\n' "$t"
    else
        printf 'path %s absent\n' "$t"
    fi
}

# Structural listing of a directory (names and types only), as soft lines.
fp_listing() {
    local d="$1" t f kind
    t="$(tilde "$d")"
    if [ ! -d "$d" ]; then printf 'soft ls %s (absent)\n' "$t"; return 0; fi
    (
        shopt -s nullglob dotglob
        for f in "$d"/*; do
            if [ -L "$f" ]; then kind=l; elif [ -d "$f" ]; then kind=d; elif [ -f "$f" ]; then kind=f; else kind=o; fi
            printf 'soft ls %s %q %s\n' "$t" "${f##*/}" "$kind"
        done
    )
}

# Number of LaunchServices records whose path is exactly the installed bundle
# (build copies registered by Spotlight/Finder are ignored). Records look like
# "path:                       /Users/me/Applications/hyprMac.app (0x1b88)".
lsregister_records() {
    local dump
    dump="$("$LSREGISTER" -dump 2>/dev/null)" || { err "lsregister -dump failed"; return 1; }
    printf '%s\n' "$dump" | /usr/bin/awk -v want="$APP_DEST" '
        /^path:/ {
            p = $0
            sub(/^path:[ \t]+/, "", p)
            sub(/ \(0x[0-9A-Fa-f]+\)$/, "", p)
            if (p == want) n++
        }
        END { print n + 0 }'
}

# State of our label in `launchctl print-disabled`: disabled | enabled | absent.
launchd_override() {
    local out
    out="$("$LAUNCHCTL" print-disabled "gui/$UID_VAL" 2>/dev/null)" || { err "launchctl print-disabled failed"; return 1; }
    printf '%s\n' "$out" | /usr/bin/awk -v want="\"$BUNDLE_ID\"" '
        $1 == want && $2 == "=>" { s = $3 }
        END {
            if (s == "") print "absent"
            else if (s == "disabled" || s == "true") print "disabled"
            else print "enabled"
        }'
}

# Deterministic fingerprint of everything install may change. stdout.
# Lines starting with "soft " are collateral-damage checks (warnings only).
take_snapshot() {
    local d rc=0
    d="$(/usr/bin/mktemp -d "$_tmp_root/hyprmac-snap.XXXXXX")" || return 1
    if _snapshot_lines "$d" >"$d/lines"; then
        LC_ALL=C /usr/bin/sort "$d/lines" || rc=1
    else
        err "could not take a snapshot"
        rc=1
    fi
    rm -rf "$d"
    return "$rc"
}

_snapshot_lines() {
    local d="$1" n p g any
    domain_export "$HOTKEY_DOMAIN" "$d/hk.plist" || return 1
    domain_export "$WM_DOMAIN" "$d/wm.plist" || return 1
    domain_export "$NC_DOMAIN" "$d/nc.plist" || return 1
    # shellcheck disable=SC2086
    pt snap "$d/hk.plist" "$d/wm.plist" "$d/nc.plist" "$BUNDLE_ID" $HOTKEY_IDS || return 1

    if "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
        printf 'launchagent %s loaded\n' "$BUNDLE_ID"
    else
        printf 'launchagent %s not-loaded\n' "$BUNDLE_ID"
    fi
    n="$(lsregister_records)" || return 1
    printf 'lsregister %s records=%s\n' "$(tilde "$APP_DEST")" "$n"

    # Files install writes: compare contents.
    fp_path "$APP_DEST" content || return 1
    fp_path "$AGENT_PLIST" content || return 1
    # Directories install may create, and runtime residue: existence + type.
    for p in "$HOME/Library" "$HOME/Library/Preferences" "$APPSUPPORT_DIR" "$HOME/Applications" \
             "$AGENT_DIR" "$SUPPORT_DIR" "$STATE_DIR" "$CONFIG_PARENT" "$CONFIG_DIR"; do
        fp_path "$p" type || return 1
    done
    while IFS= read -r p; do fp_path "$p" type || return 1; done <<EOF
$(residue_fixed)
EOF
    for g in $RESIDUE_GLOBS; do
        any=0
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            fp_path "$p" type || return 1
            any=1
        done <<EOF
$(residue_glob "$g")
EOF
        [ "$any" = 1 ] || printf 'path %s none\n' "$(residue_glob_label "$g")"
    done
    # Collateral damage: structural listings of the places we write to.
    for p in "$HOME" "$HOME/Library" "$HOME/Library/Preferences" "$AGENT_DIR" "$HOME/Applications" "$CONFIG_PARENT"; do
        fp_listing "$p" || return 1
    done
}

# Lines verify ignores: KEEP_CONFIG keeps ~/.config/hyprmac on purpose.
_verify_filter() {
    if [ "$KEEP_CONFIG" = 1 ]; then
        /usr/bin/grep -Ev '^path ~/\.config( |/hyprmac )|^soft ls ~/\.config |^soft ls ~ \.config ' "$1" || true
    else
        cat "$1"
    fi
}

# verify_snapshots BEFORE AFTER -> 0 when every hard line matches. Soft-line
# differences are printed as warnings (the user may change a shortcut while
# hyprMac is installed) but do not fail.
verify_snapshots() {
    local before="$1" after="$2" hard soft rc=0 src=0
    [ -f "$before" ] || { err "missing snapshot: $before"; return 2; }
    [ -f "$after" ] || { err "missing snapshot: $after"; return 2; }
    hard="$(/usr/bin/diff -u \
        <(_verify_filter "$before" | /usr/bin/grep -v '^soft ' || true) \
        <(_verify_filter "$after" | /usr/bin/grep -v '^soft ' || true))" || rc=$?
    soft="$(/usr/bin/diff \
        <(_verify_filter "$before" | /usr/bin/grep '^soft ' || true) \
        <(_verify_filter "$after" | /usr/bin/grep '^soft ' || true))" || src=$?
    if [ "$src" != 0 ]; then
        warn "other settings or files changed while hyprMac was installed (not caused by the installer, or worth a look):"
        printf '%s\n' "$soft" | /usr/bin/grep -E '^[<>]' | /usr/bin/sed -e 's/^< soft /    before: /' -e 's/^> soft /    after:  /' >&2
    fi
    if [ "$rc" = 0 ]; then
        ok "rollback verified: system state matches the pre-install snapshot"
        return 0
    fi
    err "rollback verification FAILED: state differs from the pre-install snapshot"
    printf '%s\n' "$hard" | /usr/bin/sed -e "1s|.*|--- before ($before)|" -e "2s|.*|+++ after ($after)|" >&2
    return 1
}

# ------------------------------------------------------------- app process --
# Only the INSTALLED binary is ever signalled (dev builds keep running).
_ere_escape() { printf '%s' "$1" | /usr/bin/sed 's/[][\.*^$+?(){}|]/\\&/g'; }
APP_PROC_RE="^$(_ere_escape "$APP_BINARY")( |\$)"
installed_app_running() { "$PKILL" -0 -f "$APP_PROC_RE" >/dev/null 2>&1; }
any_app_running() { "$PKILL" -0 -x "$APP_NAME" >/dev/null 2>&1; }

# Stop the installed app with signals only (no Apple Events, so no
# Automation/TCC prompt): SIGTERM through launchd when the agent is loaded,
# else pkill on the exact installed binary path; SIGKILL after 3 s.
quit_app() {
    if is_dry; then
        printf '%s[dry-run]%s stop %s: %s, else %s; SIGKILL after 3 s\n' "$C_DIM" "$C_RESET" "$APP_NAME" \
            "$(show_cmd "$LAUNCHCTL" kill SIGTERM "$AGENT_TARGET")" "$(show_cmd "$PKILL" -TERM -f "$APP_PROC_RE")"
        return 0
    fi
    installed_app_running || return 0
    info "stopping $APP_NAME (SIGTERM)"
    local sent=0
    if "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
        if run "$LAUNCHCTL" kill SIGTERM "$AGENT_TARGET" >/dev/null 2>&1; then sent=1; fi
    fi
    # Not started by launchd (or launchd had no process): signal it directly.
    if [ "$sent" = 0 ]; then run "$PKILL" -TERM -f "$APP_PROC_RE" || true; fi
    local i=0
    while [ "$i" -lt 30 ]; do
        installed_app_running || return 0
        sleep 0.1
        i=$((i + 1))
    done
    warn "$APP_NAME did not exit within 3 s; sending SIGKILL"
    run "$PKILL" -KILL -f "$APP_PROC_RE" || true
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

# Hotkey binding we install (⌥8 for 125, ⌥9 for 126) as a plist XML fragment.
hotkey_xml() {
    local params
    case "$1" in
        125) params="<integer>56</integer><integer>28</integer><integer>524288</integer>" ;;
        126) params="<integer>57</integer><integer>25</integer><integer>524288</integer>" ;;
        *) err "no binding defined for hotkey $1"; return 1 ;;
    esac
    printf '%s' "<dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array>$params</array><key>type</key><string>standard</string></dict></dict>"
}
hotkey_json() {
    case "$1" in
        125) printf '%s' '{"enabled":true,"value":{"parameters":[56,28,524288],"type":"standard"}}' ;;
        126) printf '%s' '{"enabled":true,"value":{"parameters":[57,25,524288],"type":"standard"}}' ;;
    esac
}

# Checked export -> edit -> import of a nested value. $1 domain, $2 edit file
# (top-level keys to merge), $3 the export the edit was computed from.
# Re-exports right before the import (to narrow the race with concurrent
# writers) and afterwards compares EVERY key with the expected result.
checked_import() {
    local domain="$1" edit="$2" before="$3" now after msg
    now="$before.now"
    after="$before.after"
    domain_export "$domain" "$now" || return 1
    if ! pt same "$before" "$now"; then
        err "$domain changed while we were editing it (System Settings open?); not importing. Re-run the command."
        return 1
    fi
    run "$DEFAULTS" import "$domain" "$edit" || return 1
    domain_export "$domain" "$after" || return 1
    if ! msg="$(pt check_import "$before" "$edit" "$after")"; then
        err "$domain did not end up as expected after the import: $msg"
        return 1
    fi
}

# ---------------------------------------------------------------- manifest --
MANIFEST_LINES=()
MANIFEST_ERRORS=""

# Parse one stored line: strips the " ;" terminator. Fails on a torn line.
_strip_line() {
    case "$1" in
        *" ;") printf '%s' "${1% ;}" ;;
        *) return 1 ;;
    esac
}

# Validate one stripped manifest entry against the closed set of actions.
_valid_entry() {
    local line="$1" a1 a2 a3 rest
    set -f  # no globbing of manifest text
    # shellcheck disable=SC2086
    set -- $line
    set +f
    case "$1" in
        dir_created)
            [ $# = 2 ] && dir_for_key "$2" >/dev/null ;;
        app_installed | lsregister | hotkeys_dict_created | hotkeys_domain_absent | wm_domain_absent | \
        agent_plist_created | launchagent_preloaded | launchagent_loaded | tcc_reset | prefs_backup | \
        ncprefs_preexisting | install_complete)
            [ $# = 1 ] ;;
        backup)
            a1="${2:-}"
            case "$a1" in
                app | launchagent) [ $# = 2 ] ;;
                residue[0-9]*)
                    case "$a1" in *[!a-z0-9]*) return 1 ;; esac
                    rest="${line#backup "$a1" }"
                    [ "$rest" != "$line" ] && is_residue_path "$rest" ;;
                *) return 1 ;;
            esac ;;
        residue_preexisting)
            rest="${line#residue_preexisting }"
            [ "$rest" != "$line" ] && is_residue_path "$rest" ;;
        hotkey)
            a1="${2:-}"; a2="${3:-}"; a3="${4:-}"
            case "$a1" in 125 | 126) ;; *) return 1 ;; esac
            case "$a2" in
                absent | untouched) [ $# = 3 ] ;;
                replaced) [ $# = 4 ] && case "$a3" in '' | *[!A-Za-z0-9+/=]*) false ;; *) true ;; esac ;;
                *) return 1 ;;
            esac ;;
        wm_globally_enabled)
            a1="${2:-}"; a2="${3:-}"
            case "$a1" in
                absent) [ $# = 2 ] ;;
                bool) [ $# = 3 ] && case "$a2" in true | false) true ;; *) false ;; esac ;;
                integer) [ $# = 3 ] && case "$a2" in -[0-9]* | [0-9]*) case "${a2#-}" in *[!0-9]*) false ;; *) true ;; esac ;; *) false ;; esac ;;
                float) [ $# = 3 ] && case "$a2" in *[!0-9eE.+-]* | '') false ;; *) true ;; esac ;;
                string) [ $# -ge 3 ] ;;
                *) return 1 ;;
            esac ;;
        config_dir_preexisting)
            [ $# = 2 ] && case "$2" in 0 | 1) true ;; *) false ;; esac ;;
        config_dir_created)
            [ $# = 2 ] && case "$2" in empty) true ;; *[!0-9a-f]*) false ;; *) [ "${#2}" = 64 ] ;; esac ;;
        launchd_override)
            [ $# = 2 ] && case "$2" in enabled | disabled | absent) true ;; *) false ;; esac ;;
        *) return 1 ;;
    esac
}

# Load and validate $MANIFEST into MANIFEST_LINES (stripped). Returns 1 and
# fills MANIFEST_ERRORS when anything is off; nothing may be undone then.
load_manifest() {
    MANIFEST_LINES=()
    MANIFEST_ERRORS=""
    local l s n=0
    while IFS= read -r l || [ -n "$l" ]; do
        n=$((n + 1))
        if ! s="$(_strip_line "$l")"; then
            MANIFEST_ERRORS="$MANIFEST_ERRORS"$'\n'"  line $n is incomplete (torn write?): $l"
            MANIFEST_LINES+=("")
            continue
        fi
        if [ "$n" = 1 ]; then
            [ "$s" = "$MANIFEST_HEADER" ] ||
                MANIFEST_ERRORS="$MANIFEST_ERRORS"$'\n'"  line 1 is not '$MANIFEST_HEADER ;' (unknown manifest version): $l"
        elif ! _valid_entry "$s"; then
            MANIFEST_ERRORS="$MANIFEST_ERRORS"$'\n'"  line $n is not a recognised action for this install: $l"
        fi
        MANIFEST_LINES+=("$s")
    done <"$MANIFEST"
    [ "$n" -gt 0 ] || MANIFEST_ERRORS="  the manifest is empty"
    [ -z "$MANIFEST_ERRORS" ]
}

manifest_problem() {
    err "the install record $(tilde "$MANIFEST") is damaged or was edited; refusing to act on it:"
    printf '%s\n' "$MANIFEST_ERRORS" | /usr/bin/sed '/^$/d' >&2
    err "nothing was changed. The state directory $(tilde "$STATE_DIR") is kept; inspect it, or restore it from a backup."
}

# manifest_has "exact entry" (stripped)
manifest_has() {
    local l
    for l in ${MANIFEST_LINES[@]+"${MANIFEST_LINES[@]}"}; do
        [ "$l" = "$1" ] && return 0
    done
    return 1
}

# Journal of completed undo steps (line numbers), one "N ;" per line.
JOURNAL_DONE=" "
load_journal() {
    JOURNAL_DONE=" "
    [ -f "$JOURNAL" ] || return 0
    local l
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
            *" ;") l="${l% ;}"; case "$l" in '' | *[!0-9]*) ;; *) JOURNAL_DONE="$JOURNAL_DONE$l " ;; esac ;;
        esac
    done <"$JOURNAL"
}
journal_has() { case "$JOURNAL_DONE" in *" $1 "*) return 0 ;; esac; return 1; }
journal_add() {
    is_dry && return 0
    printf '%s ;\n' "$1" >>"$JOURNAL"
    JOURNAL_DONE="$JOURNAL_DONE$1 "
}

# --------------------------------------------------------------- undo ops --
# Every undo is idempotent, acts only on compiled-in paths and reports failure
# through its return status. They run in "if" context (set -e is suspended),
# so every step checks errors explicitly.

undo_hotkey_absent() { # id: remove our binding (nested key: checked import)
    local id="$1" f edit res
    make_tmp
    f="$HYPR_TMP/hk-undo-$id.plist"
    edit="$HYPR_TMP/hk-undo-$id.edit.plist"
    domain_export "$HOTKEY_DOMAIN" "$f" || return 1
    res="$(pt hk_remove "$f" "$edit" "$id")" || return 1
    [ "$res" = changed ] || return 0
    checked_import "$HOTKEY_DOMAIN" "$edit" "$f" || return 1
    NEED_ACTIVATE=1
}

undo_hotkey_replaced() { # id b64: put the exact original value back
    local id="$1" b64="$2" xml want got f
    make_tmp
    f="$HYPR_TMP/hk-restore-$id.plist"
    xml="$(pt b64_xml "$b64")" || return 1
    want="$(pt b64_json "$b64")" || return 1
    domain_export "$HOTKEY_DOMAIN" "$f" || return 1
    got="$(pt get "$f" "AppleSymbolicHotKeys.$id")" || return 1
    [ "$got" != "$want" ] || return 0
    run "$DEFAULTS" write "$HOTKEY_DOMAIN" AppleSymbolicHotKeys -dict-add "$id" "$xml" || return 1
    domain_export "$HOTKEY_DOMAIN" "$f" || return 1
    got="$(pt get "$f" "AppleSymbolicHotKeys.$id")" || return 1
    [ "$got" = "$want" ] || { err "hotkey $id did not read back as its original value"; return 1; }
    NEED_ACTIVATE=1
}

undo_hotkeys_dict_created() { # top-level key: defaults delete
    local f st
    make_tmp
    f="$HYPR_TMP/hk-undo-dict.plist"
    domain_export "$HOTKEY_DOMAIN" "$f" || return 1
    st="$(pt hk_dict "$f")" || return 1
    [ "$st" = empty ] || return 0
    run "$DEFAULTS" delete "$HOTKEY_DOMAIN" AppleSymbolicHotKeys || return 1
}

undo_domain_if_empty() { # domain
    local f n
    make_tmp
    f="$HYPR_TMP/domain-$1.plist"
    domain_export "$1" "$f" || return 1
    n="$(pt dict_len "$f")" || return 1
    if [ "$n" = 0 ]; then
        if is_dry; then run "$DEFAULTS" delete "$1"; return 0; fi
        run "$DEFAULTS" delete "$1" >/dev/null 2>&1 || true
        domain_export "$1" "$f" || return 1
        [ "$(pt dict_len "$f")" = 0 ] || return 1
    fi
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
            [ "$(pt type "$f" "$WM_KEY")" != absent ] || return 0
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

undo_dir_created() { # key (support/state are finalised separately)
    local p
    p="$(dir_for_key "$1")" || return 1
    [ -d "$p" ] && [ ! -L "$p" ] || return 0
    if [ -n "$(/bin/ls -A "$p" 2>/dev/null)" ]; then
        if [ "$KEEP_CONFIG" = 1 ] && [ "$1" = dotconfig ]; then return 0; fi
        warn "not removing $(tilde "$p"): it is not empty"
        return 0
    fi
    run rmdir "$p" || return 1
}

# Restore a backup made by install. Name and destination are fixed (or an
# allowlisted residue path, validated when the manifest was loaded).
undo_backup() { # name [residue path]
    local name="$1" path
    case "$name" in
        app) path="$APP_DEST" ;;
        launchagent) path="$AGENT_PLIST" ;;
        residue*) path="$2"; is_residue_path "$path" || return 1 ;;
        *) return 1 ;;
    esac
    [ -e "$BACKUP_DIR/$name" ] || [ -L "$BACKUP_DIR/$name" ] || return 0
    if [ -e "$path" ] || [ -L "$path" ]; then run rm -rf "$path" || return 1; fi
    run mv "$BACKUP_DIR/$name" "$path" || return 1
}

# Restore pre-existing app prefs: import first (merges keys), then delete the
# keys the app added, then check the domain equals the backup. The backup file
# itself is only discarded with the state dir after the rollback verified.
undo_prefs_backup() {
    local bak="$BACKUP_DIR/prefs.plist" cur k keys
    [ -f "$bak" ] || { err "prefs backup missing: $bak"; return 1; }
    run "$DEFAULTS" import "$BUNDLE_ID" "$bak" || return 1
    is_dry && return 0
    make_tmp
    cur="$HYPR_TMP/prefs-now.plist"
    domain_export "$BUNDLE_ID" "$cur" || return 1
    keys="$(pt extra_keys "$cur" "$bak")" || return 1
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        run "$DEFAULTS" delete "$BUNDLE_ID" "$k" || return 1
    done <<EOF
$keys
EOF
    domain_export "$BUNDLE_ID" "$cur" || return 1
    pt same "$cur" "$bak" || { err "restored $BUNDLE_ID preferences differ from the backup"; return 1; }
}

undo_launchagent_loaded() {
    local out
    if is_dry; then run "$LAUNCHCTL" bootout "$AGENT_TARGET"; return 0; fi
    "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1 || return 0
    printf '%s  $ %s%s\n' "$C_DIM" "$(show_cmd "$LAUNCHCTL" bootout "$AGENT_TARGET")" "$C_RESET" >&2
    out="$("$LAUNCHCTL" bootout "$AGENT_TARGET" 2>&1)" || {
        case "$out" in
            *"No such process"* | *"not loaded"* | *"Could not find"*) ;;
            *) err "launchctl bootout failed: $out"; return 1 ;;
        esac
    }
}

# A LaunchAgent with our label was loaded before install: load the restored
# plist again.
undo_launchagent_preloaded() {
    [ -f "$AGENT_PLIST" ] || { err "cannot reload the previous LaunchAgent: $(tilde "$AGENT_PLIST") is missing"; return 1; }
    if ! is_dry && "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then return 0; fi
    run "$LAUNCHCTL" bootstrap "gui/$UID_VAL" "$AGENT_PLIST" || return 1
}

undo_launchd_override() { # original: enabled | disabled | absent
    local now
    now="$(launchd_override)" || return 1
    case "$1" in
        disabled) [ "$now" = disabled ] || run "$LAUNCHCTL" disable "$AGENT_TARGET" || return 1 ;;
        *) [ "$now" != disabled ] || run "$LAUNCHCTL" enable "$AGENT_TARGET" || return 1 ;;
    esac
}

# Remove the config dir install created. Unchanged: deleted. Edited by the
# user: moved to the Trash (or next to it) and the location printed.
undo_config_dir_created() { # sha256 of the init.lua we wrote | empty
    local want="$1" content dest ts
    [ -e "$CONFIG_DIR" ] || [ -L "$CONFIG_DIR" ] || return 0
    if [ "$KEEP_CONFIG" = 1 ]; then
        info "KEEP_CONFIG=1: keeping $(tilde "$CONFIG_DIR")"
        return 0
    fi
    if [ -d "$CONFIG_DIR" ] && [ ! -L "$CONFIG_DIR" ]; then
        content="$(/bin/ls -A "$CONFIG_DIR")"
        if { [ "$want" = empty ] && [ -z "$content" ]; } ||
           { [ "$content" = init.lua ] && [ -f "$CONFIG_DIR/init.lua" ] && [ "$(sha_of_file "$CONFIG_DIR/init.lua")" = "$want" ]; }; then
            run rm -rf "$CONFIG_DIR" || return 1
            return 0
        fi
    fi
    ts="$(/bin/date +%Y%m%d-%H%M%S)"
    dest="$HOME/.Trash/hyprmac-config-$ts"
    if is_dry; then run mv "$CONFIG_DIR" "$dest"; return 0; fi
    if [ -d "$HOME/.Trash" ] && mv "$CONFIG_DIR" "$dest" 2>/dev/null; then
        warn "your edited $(tilde "$CONFIG_DIR") was moved to the Trash: $(tilde "$dest")"
        return 0
    fi
    dest="$HOME/hyprmac-config-$ts"
    run mv "$CONFIG_DIR" "$dest" || return 1
    warn "your edited $(tilde "$CONFIG_DIR") was moved to $(tilde "$dest") (the Trash was not writable)"
}

# Dispatch one stripped, validated manifest entry to its fixed undo.
undo_entry() {
    local line="$1"
    set -f  # no globbing of manifest text
    # shellcheck disable=SC2086
    set -- $line
    set +f
    case "$1" in
        install_complete | config_dir_preexisting | residue_preexisting) return 0 ;;
        dir_created) undo_dir_created "$2" ;;
        app_installed) if [ -e "$APP_DEST" ] || [ -L "$APP_DEST" ]; then run rm -rf "$APP_DEST" || return 1; fi ;;
        agent_plist_created) if [ -e "$AGENT_PLIST" ] || [ -L "$AGENT_PLIST" ]; then run rm -f "$AGENT_PLIST" || return 1; fi ;;
        backup) undo_backup "$2" "${line#backup "$2" }" ;;
        lsregister) run "$LSREGISTER" -u "$APP_DEST" || warn "lsregister -u failed (ignored)" ;;
        hotkey)
            case "$3" in
                absent) undo_hotkey_absent "$2" ;;
                replaced) undo_hotkey_replaced "$2" "$4" ;;
                untouched) return 0 ;;
            esac ;;
        hotkeys_dict_created) undo_hotkeys_dict_created ;;
        hotkeys_domain_absent) undo_domain_if_empty "$HOTKEY_DOMAIN" ;;
        wm_globally_enabled) undo_wm "${line#wm_globally_enabled }" ;;
        wm_domain_absent) undo_domain_if_empty "$WM_DOMAIN" ;;
        launchagent_loaded) undo_launchagent_loaded ;;
        launchagent_preloaded) undo_launchagent_preloaded ;;
        launchd_override) undo_launchd_override "$2" ;;
        tcc_reset) run "$TCCUTIL" reset Accessibility "$BUNDLE_ID" >/dev/null || warn "tccutil reset failed (ignored)" ;;
        config_dir_created) undo_config_dir_created "$2" ;;
        prefs_backup) undo_prefs_backup ;;
        ncprefs_preexisting) restore_ncprefs ;;
        *) err "unexpected manifest entry: $line"; return 1 ;;
    esac
}

# --------------------------------------------------------------- residue --
clean_ncprefs() {
    local f edit result
    make_tmp
    f="$HYPR_TMP/nc.plist"
    edit="$HYPR_TMP/nc-filtered.plist"
    domain_export "$NC_DOMAIN" "$f" || return 1
    result="$(pt nc_filter "$f" "$edit" "$BUNDLE_ID")" || return 1
    if [ "$result" = changed ]; then
        checked_import "$NC_DOMAIN" "$edit" "$f" || return 1
        run "$KILLALL" usernoted >/dev/null 2>&1 || true
    fi
}

restore_ncprefs() {
    local saved="$BACKUP_DIR/ncprefs-entry.plist" f edit result
    [ -f "$saved" ] || { err "notification settings backup missing: $saved"; return 1; }
    make_tmp
    f="$HYPR_TMP/nc-restore.plist"
    edit="$HYPR_TMP/nc-restored.plist"
    domain_export "$NC_DOMAIN" "$f" || return 1
    result="$(pt nc_restore "$f" "$edit" "$saved")" || return 1
    if [ "$result" = changed ]; then
        checked_import "$NC_DOMAIN" "$edit" "$f" || return 1
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
        is_residue_path "$p" || continue
        manifest_has "residue_preexisting $p" && continue
        if [ -e "$p" ] || [ -L "$p" ]; then run rm -rf "$p" || failed=1; fi
    done <<EOF
$(residue_paths)
EOF
    if ! manifest_has "ncprefs_preexisting"; then clean_ncprefs || failed=1; fi
    return "$failed"
}

# ------------------------------------------------------------- uninstall --
INTERRUPTED=0
on_interrupt() {
    INTERRUPTED=1
    warn "interrupt received: finishing the current step, then stopping (re-run 'make uninstall' to continue)"
}

# do_uninstall [rollback]: undo everything recorded in the manifest, clean
# residue, then verify against before.snapshot.
# Exit status: 0 verified; 1 failed (state kept); 3 undone but UNVERIFIED
# (no before.snapshot); 130 interrupted (state kept, re-run to continue).
do_uninstall() {
    local mode="${1:-uninstall}" failures=0 i line
    NEED_ACTIVATE=0
    if [ ! -f "$MANIFEST" ]; then
        if [ -f "$VERIFY_FAILED" ]; then
            warn "the last uninstall did not verify; its state is in $(tilde "$VERIFY_DIR") (see 'make verify-rollback')"
        fi
        info "no install manifest found at $(tilde "$MANIFEST"); nothing to undo"
        return 0
    fi
    if ! load_manifest; then
        manifest_problem
        return 1
    fi
    load_journal
    [ "$JOURNAL_DONE" = " " ] || info "resuming an earlier uninstall (journal: $(tilde "$JOURNAL"))"
    quit_app

    title "removing app residue"
    clean_residue || failures=$((failures + 1))

    title "undoing recorded install actions"
    i=$((${#MANIFEST_LINES[@]} - 1))
    while [ "$i" -ge 1 ]; do
        if [ "$INTERRUPTED" = 1 ]; then break; fi
        line="${MANIFEST_LINES[$i]}"
        i=$((i - 1))
        journal_has "$((i + 2))" && continue
        case "$line" in
            "dir_created support" | "dir_created state") continue ;;  # finalised below
        esac
        if undo_entry "$line"; then
            journal_add "$((i + 2))"
        else
            err "failed to undo: $line"
            failures=$((failures + 1))
        fi
    done
    if [ "$NEED_ACTIVATE" = 1 ]; then activate_hotkeys; fi
    cleanup_tmp

    if is_dry; then
        info "dry run: nothing was changed"
        return 0
    fi
    if [ "$INTERRUPTED" = 1 ]; then
        err "uninstall interrupted; progress is journaled in $(tilde "$JOURNAL"). Re-run 'make uninstall' to finish."
        return 130
    fi
    if [ "$failures" -gt 0 ]; then
        err "$failures undo step(s) failed. Nothing was deleted: the manifest, journal and backups are kept in $(tilde "$STATE_DIR")."
        err "fix the problem above and re-run 'make uninstall'; finished steps are not repeated."
        return 1
    fi
    _finalise_uninstall "$mode"
}

# Every undo succeeded: move the state aside, drop the dirs we created, take
# the after-snapshot and verify. Verified: delete everything. Not verified:
# keep it all in $VERIFY_DIR and make install refuse until resolved.
_finalise_uninstall() {
    local mode="$1" verified=0 have_before=0
    [ -f "$BEFORE_SNAPSHOT" ] && have_before=1
    rm -rf "$VERIFY_DIR"
    mkdir -p "$VERIFY_DIR" || return 1
    mv "$STATE_DIR" "$VERIFY_DIR/state" || { err "could not move $(tilde "$STATE_DIR") aside"; return 1; }
    if manifest_has "dir_created support"; then
        if [ -z "$(/bin/ls -A "$SUPPORT_DIR" 2>/dev/null)" ]; then
            run rmdir "$SUPPORT_DIR" || true
        else
            warn "not removing $(tilde "$SUPPORT_DIR"): it is not empty"
        fi
    fi
    if [ "$have_before" = 0 ]; then
        rm -rf "$VERIFY_DIR"
        err "UNVERIFIED: every recorded action was undone, but there is no pre-install snapshot to compare with"
        return 3
    fi
    take_snapshot >"$VERIFY_DIR/after.snapshot" || { err "could not take the after-snapshot"; : >"$VERIFY_FAILED"; return 1; }
    if verify_snapshots "$VERIFY_DIR/state/before.snapshot" "$VERIFY_DIR/after.snapshot"; then
        verified=1
    fi
    if [ "$verified" = 1 ]; then
        rm -rf "$VERIFY_DIR"
        if [ "$mode" = rollback ]; then ok "install rolled back"; else ok "hyprMac uninstalled"; fi
        return 0
    fi
    : >"$VERIFY_FAILED"
    err "the old install state, its backups and both snapshots are kept in $(tilde "$VERIFY_DIR")."
    err "fix the differences above, then run 'make verify-rollback'; 'make install' refuses until it passes."
    return 1
}
