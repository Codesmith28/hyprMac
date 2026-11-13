#!/bin/bash
# Install hyprMac with recorded, exactly reversible system changes.
#
#   scripts/install.sh [--dry-run | --preflight]
#
# --preflight is strictly read-only: it reports what an install would change
# on this Mac using only defaults read/export, launchctl print, security
# find-identity and test -e.
#
# Every change is first appended to the manifest
# (~/Library/Application Support/hyprMac/install/manifest); uninstall.sh
# replays it in reverse. A snapshot of everything we may touch is taken
# before the first change so the rollback can be verified.
#
# Environment: APP_SRC (app bundle to install, default ../build/hyprMac.app),
# HYPR_WM_APPLY_CMD, HYPR_WM_ACTIVE_CMD, KEEP_CONFIG (uninstall), DRY_RUN=1, and the command
# overrides listed in lib/common.sh. HYPR_FAIL_AT=<step> injects a failure
# (used by the sandbox tests).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<USAGE
usage: $(basename "$0") [--dry-run | --preflight]

Installs $APP_NAME.app to ~/Applications, adds the ⌥8/⌥9 "Switch to Desktop"
shortcuts (only if unbound), turns Stage Manager off, installs a LaunchAgent and
asks for Accessibility access. Everything is recorded so 'make uninstall'
restores the previous state exactly. If you created the optional local signing
identity ('make sign-identity'), the installed app is signed with it.

  --dry-run    print every action without performing it
  --preflight  read-only report of what would change on this Mac
USAGE
}

PREFLIGHT=0
for arg in "$@"; do
    case "$arg" in
        -n | --dry-run) DRY_RUN=1 ;;
        --preflight) PREFLIGHT=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $arg" ;;
    esac
done

sandbox_guard

: "${APP_SRC:=$SCRIPT_DIR/../build/$APP_NAME.app}"

# ---------------------------------------------------------------- preflight --
# Read-only. Allowed system reads: defaults export (piped, never to a file),
# launchctl print, and test -e. The rest is local text parsing.

# Human-readable symbolic hotkey from its canonical JSON (argv[1]).
PY_HOTKEY_DESC='
import json, sys
v = json.loads(sys.argv[1])
p = v.get("value", {}).get("parameters", [])
if len(p) != 3:
    print("unrecognised binding " + sys.argv[1]); sys.exit()
ch, kc, mods = p
names = [(262144, "⌃"), (524288, "⌥"), (131072, "⇧"), (1048576, "⌘")]
m = "".join(sym for bit, sym in names if mods & bit)
key = chr(ch) if 32 < ch < 127 else (" keycode %d" % kc if m else "keycode %d" % kc)
state = "enabled" if v.get("enabled") else "disabled"
print("%s%s (%s)" % (m, key, state))
'

# canon_from_defaults DOMAIN KEYPATH -> canonical JSON | absent
canon_from_defaults() {
    local out
    out="$("$DEFAULTS" export "$1" - | pt get /dev/stdin "$2")" || return 1
    printf '%s' "$out"
}

json_type() {
    case "$1" in
        true | false) printf bool ;;
        \"*) printf string ;;
        *.* | *e*) printf float ;;
        *) printf integer ;;
    esac
}

# One line on the optional local signing identity (read-only: security find-identity).
preflight_signing() {
    local h
    h="$(sign_identity_hash)"
    if [ -n "$h" ]; then
        pf "signing identity" "\"$SIGN_IDENTITY_NAME\" present → the app is signed with it (Accessibility grant survives upgrades)"
    else
        pf "signing identity" "none → ad-hoc signature (make sign-identity is optional; see docs/LIMITATIONS.md)"
    fi
}

# Already installed: an install only replaces the bundle; report that and
# what uninstall would put back, from the manifest.
preflight_installed() {
    local line action rest
    pf "$(tilde "$APP_DEST")" "$( [ -e "$APP_DEST" ] && echo "present (ours) → would be replaced" || echo "MISSING → would be installed again")"
    if "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
        pf "LaunchAgent service" "$AGENT_TARGET loaded → would be reloaded"
    else
        pf "LaunchAgent service" "$AGENT_TARGET not loaded → would be bootstrapped"
    fi
    preflight_signing
    pf "other settings" "unchanged by an upgrade; recorded originals that uninstall restores:"
    load_manifest || { manifest_problem; return 1; }
    for line in ${MANIFEST_LINES[@]+"${MANIFEST_LINES[@]}"}; do
        action="${line%% *}"; rest="${line#* }"
        case "$action" in
            hotkey) case "$rest" in
                    *absent) pf "" "hotkey ${rest%% *}: was absent → removed on uninstall" ;;
                    *) pf "" "hotkey ${rest%% *}: was already bound → never touched" ;;
                esac ;;
            wm_globally_enabled) pf "" "Stage Manager: was ${rest} → restored on uninstall" ;;
            config_dir_preexisting) if [ "$rest" = 1 ]; then pf "" "~/.config/hyprmac: pre-existing → kept"; fi ;;
            config_dir_created) pf "" "~/.config/hyprmac: created by install → removed (unless KEEP_CONFIG=1)" ;;
            residue_preexisting) pf "" "$(tilde "$rest"): pre-existing → restored from backup" ;;
            signing_identity_created) pf "" "\"$SIGN_IDENTITY_NAME\": created while installed → removed on uninstall" ;;
        esac
    done
}

do_preflight() {
    local v desc id t
    pf() { printf '  %-24s %s\n' "$1" "$2"; }
    title "hyprMac install preflight (read-only: nothing on this Mac is changed)"
    pf "user / HOME" "uid $UID_VAL, $HOME"

    if [ -e "$MANIFEST" ]; then
        pf "install record" "present ($(tilde "$MANIFEST")) → install would only replace the app bundle and reload the agent"
    else
        pf "install record" "none → fresh install; a before-snapshot would be taken first"
    fi
    if [ -e "$APP_SRC/Contents/MacOS/$APP_NAME" ]; then
        pf "app to install" "$APP_SRC"
    else
        pf "app to install" "MISSING at $APP_SRC (run 'make app' first)"
    fi
    if [ -e "$MANIFEST" ]; then
        preflight_installed
        info "preflight finished; no changes were made"
        return 0
    fi
    if [ -e "$APP_DEST" ]; then
        pf "$(tilde "$APP_DEST")" "present, not installed by us → would be moved aside and restored on uninstall"
    else
        pf "$(tilde "$APP_DEST")" "absent → would be installed"
    fi

    local want125="⌥8" want126="⌥9"
    for id in $HOTKEY_IDS; do
        v="$(canon_from_defaults "$HOTKEY_DOMAIN" "AppleSymbolicHotKeys.$id")"
        if [ "$v" = absent ]; then
            if [ "$id" = 125 ]; then desc="$want125"; else desc="$want126"; fi
            pf "hotkey $id" "absent → would add $desc \"Switch to Desktop $((id - 117))\" (removed again on uninstall)"
        else
            pf "hotkey $id" "already bound to $("$PYTHON" -I -c "$PY_HOTKEY_DESC" "$v") → left untouched"
            pf "" "raw: $v"
        fi
    done

    v="$(canon_from_defaults "$WM_DOMAIN" "$WM_KEY")"
    if [ "$v" = absent ]; then
        pf "Stage Manager" "$WM_DOMAIN $WM_KEY is absent → would be set to false (deleted again on uninstall)"
    else
        t="$(json_type "$v")"
        pf "Stage Manager" "$WM_DOMAIN $WM_KEY = $v ($t) → would be set to false (restored to $v on uninstall)"
        case "$v" in
            false | 0 | 0.0) ;;
            *) pf "" "note: Stage Manager is on now. $WM_NOTE." ;;
        esac
    fi

    if [ -e "$AGENT_PLIST" ]; then
        pf "LaunchAgent plist" "present at $(tilde "$AGENT_PLIST") → would be moved aside, restored on uninstall"
    else
        pf "LaunchAgent plist" "absent → would be created at $(tilde "$AGENT_PLIST")"
    fi
    if "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
        pf "LaunchAgent service" "$AGENT_TARGET is loaded → would be reloaded"
    else
        pf "LaunchAgent service" "$AGENT_TARGET not loaded → would be bootstrapped (starts $APP_NAME)"
    fi
    if [ -e "$HOME/Library/LaunchAgents" ]; then :; else
        pf "" "~/Library/LaunchAgents is missing → would be created (removed on uninstall)"
    fi

    if [ -e "$CONFIG_DIR" ]; then
        pf "$(tilde "$CONFIG_DIR")" "exists → left untouched (also on uninstall)"
    else
        pf "$(tilde "$CONFIG_DIR")" "absent → would be created with init.lua (removed on uninstall unless KEEP_CONFIG=1)"
    fi

    if [ -e "$ACTIVATE_SETTINGS" ]; then
        pf "activateSettings" "present → shortcut changes apply without logging out"
    else
        pf "activateSettings" "MISSING → you would have to log out for ⌥8/⌥9 to work"
    fi
    preflight_signing
    pf "Accessibility" "would run: tccutil reset Accessibility $BUNDLE_ID, then open System Settings (TCC itself is not readable)"

    local p any=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -e "$p" ]; then
            pf "existing app data" "$(tilde "$p") → backed up, restored exactly on uninstall"
            any=1
        fi
    done <<EOF
$(residue_paths)
EOF
    [ "$any" = 1 ] || pf "existing app data" "none"
    local nc
    nc="$("$DEFAULTS" export "$NC_DOMAIN" - | pt nc_has /dev/stdin "$BUNDLE_ID")"
    if [ "$nc" = present ]; then
        pf "notification settings" "entry for $BUNDLE_ID exists → backed up, restored on uninstall"
    else
        pf "notification settings" "no entry for $BUNDLE_ID"
    fi
    pf "LaunchServices" "not inspected here (lsregister -dump is outside the preflight's read set)"
    info "preflight finished; no changes were made"
}

if [ "$PREFLIGHT" = 1 ]; then
    do_preflight
    exit 0
fi

[ -x "$APP_SRC/Contents/MacOS/$APP_NAME" ] ||
    die "no app bundle at $APP_SRC (run 'make app' or set APP_SRC)"
APP_SRC="$(cd "$APP_SRC" && pwd -P)"
if [ -d "$APP_DEST" ] && [ "$(cd "$APP_DEST" && pwd -P)" = "$APP_SRC" ]; then
    die "APP_SRC is the installed bundle itself ($APP_SRC)"
fi

# ------------------------------------------------------------ error handling --
CURRENT_STEP="init"
WM_ORIG="absent"
INSTALL_NOTES=()
MODE="install"
PENDING_DIRS=()

fail() { err "$*"; return 1; }
# Was this entry recorded during this run? (reads the manifest file)
manifest_line_recorded() { /usr/bin/grep -qxF "$1 ;" "$MANIFEST" 2>/dev/null; }

step() {
    CURRENT_STEP="$1"
    title "[$1] $2"
    if [ "${HYPR_FAIL_AT:-}" = "$1" ]; then
        err "injected failure at step '$1' (HYPR_FAIL_AT)"
        return 1
    fi
}

on_error() {
    local rc=$?
    # set -E makes command substitutions inherit this trap: let the failure
    # propagate to the main shell instead of rolling back twice.
    if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then exit "$rc"; fi
    trap - ERR
    set +e
    err "install failed during step '$CURRENT_STEP' (exit $rc)"
    if is_dry; then exit 1; fi
    if [ "$MODE" = upgrade ]; then
        err "upgrade failed; the original install record is untouched. Fix the problem and re-run 'make install', or run 'make uninstall'."
        exit 1
    fi
    if [ -f "$MANIFEST" ]; then
        warn "rolling back the changes made so far"
        trap on_interrupt INT TERM HUP
        do_uninstall rollback || err "rollback incomplete; fix the problem and run 'make uninstall'"
    else
        # The state step may have created dirs and the snapshot before the
        # manifest existed: remove exactly those.
        rm -f "$BEFORE_SNAPSHOT" "$BEFORE_SNAPSHOT.tmp" 2>/dev/null
        rmdir "$BACKUP_DIR" 2>/dev/null
        local i=$((${#PENDING_DIRS[@]} - 1))
        while [ "$i" -ge 0 ]; do
            rmdir "${PENDING_DIRS[$i]}" 2>/dev/null
            i=$((i - 1))
        done
    fi
    cleanup_tmp
    exit 1
}
trap on_error ERR
trap cleanup_tmp EXIT

# ------------------------------------------------------------------ helpers --
# Missing ancestors of $1 (inclusive), outermost first, one per line.
missing_dirs() {
    local p="$1" list=""
    while [ ! -d "$p" ]; do
        list="$p"$'\n'"$list"
        p="$(dirname "$p")"
    done
    printf '%s' "$list"
}

# Create a directory (and missing parents), recording each one created.
mkdir_recorded() {
    local d key
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        key="$(key_for_dir "$d")" || fail "refusing to create unexpected directory $d"
        record "dir_created $key"
        run mkdir "$d"
    done <<EOF
$(missing_dirs "$1")
EOF
}

xml_escape() { printf '%s' "$1" | /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

agent_plist_xml() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$BUNDLE_ID</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml_escape "$APP_BINARY")</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
}

find_config_example() {
    local c
    for c in "$APP_SRC/Contents/Resources/init.lua.example" \
             "$SCRIPT_DIR/../init.lua.example" \
             "$SCRIPT_DIR/../config/init.lua.example"; do
        if [ -f "$c" ]; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

# ------------------------------------------------------------------ upgrade --
do_upgrade() {
    MODE="upgrade"
    title "existing install found: replacing the app bundle only"
    info "recorded original values in $(tilde "$STATE_DIR") are kept as they are"
    load_manifest || { manifest_problem; exit 1; }
    step upgrade_app "replacing $(tilde "$APP_DEST")"
    quit_app
    if ! is_dry && "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
        run "$LAUNCHCTL" bootout "$AGENT_TARGET" || warn "launchctl bootout failed (continuing)"
    fi
    # With the local signing identity the designated requirement is the same for every build:
    # when the installed app already carries it, the Accessibility grant stays valid.
    local sid keep_tcc=0
    sid="$(sign_identity_hash)"
    if [ -n "$sid" ] && [ -d "$APP_DEST" ] && bundle_signed_with "$APP_DEST" "$sid"; then keep_tcc=1; fi
    if [ -e "$APP_DEST" ]; then run rm -rf "$APP_DEST"; fi
    run /usr/bin/ditto "$APP_SRC" "$APP_DEST"
    sign_installed_app
    run "$LSREGISTER" -f "$APP_DEST"
    if [ "$keep_tcc" = 1 ] && ! is_dry && bundle_signed_with "$APP_DEST" "$sid"; then
        step upgrade_tcc "keeping the Accessibility grant (same signing identity as the installed build)"
    else
        # Ad-hoc signing: macOS ties the Accessibility grant to the old build's code hash, so the
        # toggle in System Settings still looks "on" but no longer applies. Reset it so the new
        # build gets a clean prompt (the manifest's tcc_reset from the first install still covers
        # uninstall).
        keep_tcc=0
        step upgrade_tcc "resetting Accessibility for the new build (re-enable it when asked)"
        run "$TCCUTIL" reset Accessibility "$BUNDLE_ID" || warn "tccutil reset failed (continuing)"
    fi
    if manifest_has "launchagent_loaded" && [ -f "$AGENT_PLIST" ]; then
        step upgrade_agent "reloading the LaunchAgent"
        run "$LAUNCHCTL" bootstrap "gui/$UID_VAL" "$AGENT_PLIST"
    fi
    if [ "$keep_tcc" = 0 ]; then run "$OPEN" "$ACCESSIBILITY_URL" || warn "could not open System Settings"; fi
    if is_dry; then
        info "dry run: nothing was changed"
    elif [ "$keep_tcc" = 1 ]; then
        ok "hyprMac upgraded; the Accessibility grant still applies (signed with \"$SIGN_IDENTITY_NAME\")"
    else
        ok "hyprMac upgraded — re-enable hyprMac under Accessibility (remove any old hyprMac entry first)"
    fi
}

# ------------------------------------------------------------- fresh install --
do_install() {
    local f id changed

    step snapshot "recording the current system state"
    make_tmp
    take_snapshot >"$HYPR_TMP/before.snapshot"

    step state_dir "creating $(tilde "$STATE_DIR")"
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        PENDING_DIRS+=("$d")
    done <<EOF
$(missing_dirs "$STATE_DIR")
EOF
    for d in ${PENDING_DIRS[@]+"${PENDING_DIRS[@]}"}; do
        key_for_dir "$d" >/dev/null || fail "refusing to create unexpected directory $d (is ~/Library/Application Support missing?)"
    done
    if is_dry; then
        for d in ${PENDING_DIRS[@]+"${PENDING_DIRS[@]}"}; do run mkdir "$d"; done
        run cp "$HYPR_TMP/before.snapshot" "$BEFORE_SNAPSHOT"
    else
        for d in ${PENDING_DIRS[@]+"${PENDING_DIRS[@]}"}; do mkdir "$d"; done
        mkdir -p "$BACKUP_DIR"
        # The snapshot lands before the manifest exists: a manifest therefore
        # always has a snapshot to verify against.
        cp "$HYPR_TMP/before.snapshot" "$BEFORE_SNAPSHOT.tmp"
        mv "$BEFORE_SNAPSHOT.tmp" "$BEFORE_SNAPSHOT"
        printf '%s ;\n' "$MANIFEST_HEADER" >"$MANIFEST"
    fi
    for d in ${PENDING_DIRS[@]+"${PENDING_DIRS[@]}"}; do record "dir_created $(key_for_dir "$d")"; done
    PENDING_DIRS=()

    step residue_scan "backing up app data that already exists"
    local p n=0 prefs="$HOME/Library/Preferences/$BUNDLE_ID.plist"
    while IFS= read -r p; do
        if [ -n "$p" ] && { [ -e "$p" ] || [ -L "$p" ]; }; then
            warn "$(tilde "$p") already exists; backing it up (restored on uninstall)"
            record "residue_preexisting $p"
            if [ "$p" = "$prefs" ]; then
                # Through cfprefsd, so its cache and the file stay coherent.
                record "prefs_backup"
                if is_dry; then run "$DEFAULTS" export "$BUNDLE_ID" "$BACKUP_DIR/prefs.plist"
                else "$DEFAULTS" export "$BUNDLE_ID" "$BACKUP_DIR/prefs.plist"; fi
            else
                n=$((n + 1))
                record "backup residue$n $p"
                run /usr/bin/ditto "$p" "$BACKUP_DIR/residue$n"
            fi
        fi
    done <<EOF
$(residue_paths)
EOF
    local nc
    f="$HYPR_TMP/nc.plist"
    domain_export "$NC_DOMAIN" "$f"
    nc="$(pt nc_has "$f" "$BUNDLE_ID")"
    if [ "$nc" = present ]; then
        warn "notification settings for $BUNDLE_ID already exist; backing them up (restored on uninstall)"
        record "ncprefs_preexisting"
        if is_dry; then
            run pt nc_save "$f" "$BACKUP_DIR/ncprefs-entry.plist" "$BUNDLE_ID"
        else
            pt nc_save "$f" "$BACKUP_DIR/ncprefs-entry.plist" "$BUNDLE_ID"
        fi
    fi

    step app "installing $APP_NAME.app to $(tilde "$APP_DEST")"
    mkdir_recorded "$HOME/Applications"
    if [ -e "$APP_DEST" ] || [ -L "$APP_DEST" ]; then
        warn "$(tilde "$APP_DEST") exists; moving it aside (restored on uninstall)"
        record "backup app"
        run mv "$APP_DEST" "$BACKUP_DIR/app"
    fi
    record "app_installed"
    run /usr/bin/ditto "$APP_SRC" "$APP_DEST"
    sign_installed_app

    step lsregister "registering with LaunchServices"
    record "lsregister"
    run "$LSREGISTER" -f "$APP_DEST"

    step hotkeys "adding ⌥8/⌥9 \"Switch to Desktop\" shortcuts (if unbound)"
    # Single-key merges with `defaults write -dict-add`: no export/import
    # window in which a concurrent change could be reverted.
    changed=0
    f="$HYPR_TMP/hk.plist"
    domain_export "$HOTKEY_DOMAIN" "$f"
    local nk hkd st
    nk="$(pt dict_len "$f")"
    hkd="$(pt hk_dict "$f")"
    if [ "$nk" = 0 ]; then record "hotkeys_domain_absent"; fi
    if [ "$hkd" = absent ]; then record "hotkeys_dict_created"; fi
    for id in $HOTKEY_IDS; do
        st="$(pt hk_state "$f" "$id")"
        if [ "$st" != absent ]; then
            info "symbolic hotkey $id is already defined ($st); leaving it untouched"
            record "hotkey $id untouched"
            continue
        fi
        record "hotkey $id absent"
        local xml
        xml="$(hotkey_xml "$id")"
        run "$DEFAULTS" write "$HOTKEY_DOMAIN" AppleSymbolicHotKeys -dict-add "$id" "$xml"
        changed=1
    done
    if [ "$changed" = 1 ] && ! is_dry; then
        domain_export "$HOTKEY_DOMAIN" "$f"
        for id in $HOTKEY_IDS; do
            if manifest_line_recorded "hotkey $id absent"; then
                [ "$(pt get "$f" "AppleSymbolicHotKeys.$id")" = "$(hotkey_json "$id")" ] ||
                    fail "hotkey $id did not read back as written"
            fi
        done
    fi
    if [ "$changed" = 1 ]; then activate_hotkeys; fi

    step wm "turning Stage Manager off"
    f="$HYPR_TMP/wm.plist"
    domain_export "$WM_DOMAIN" "$f"
    local nkeys
    nkeys="$(pt dict_len "$f")"
    if [ "$nkeys" = 0 ]; then record "wm_domain_absent"; fi
    if plist_has "$f" "$WM_KEY"; then
        local wtype wval
        wtype="$("$PLUTIL" -type "$WM_KEY" "$f")"
        case "$wtype" in
            bool | integer | float | string) ;;
            *) fail "$WM_DOMAIN $WM_KEY has unsupported type '$wtype'; refusing to change it" ;;
        esac
        wval="$("$PLUTIL" -extract "$WM_KEY" raw "$f")"
        record "wm_globally_enabled $wtype $wval"
        WM_ORIG="$wtype $wval"
    else
        record "wm_globally_enabled absent"
        WM_ORIG="absent"
    fi
    run "$DEFAULTS" write "$WM_DOMAIN" "$WM_KEY" -bool false
    wm_apply

    step wm_verify "checking that Stage Manager reads back as off"
    if is_dry; then
        run "$DEFAULTS" read "$WM_DOMAIN" "$WM_KEY"
    else
        local readback
        readback="$("$DEFAULTS" read "$WM_DOMAIN" "$WM_KEY" 2>/dev/null)" || readback="(unreadable)"
        case "$readback" in
            0 | false) ok "$WM_DOMAIN $WM_KEY reads back as off" ;;
            *) fail "$WM_DOMAIN $WM_KEY reads back as '$readback' after writing false" ;;
        esac
    fi
    if wm_maybe_still_active "$WM_ORIG"; then
        warn "Stage Manager may still be visible: $WM_NOTE."
        INSTALL_NOTES+=("$WM_NOTE.")
    fi

    step config "creating $(tilde "$CONFIG_DIR")"
    if [ -e "$CONFIG_DIR" ] || [ -L "$CONFIG_DIR" ]; then
        info "$(tilde "$CONFIG_DIR") already exists; leaving it untouched"
        record "config_dir_preexisting 1"
    else
        record "config_dir_preexisting 0"
        mkdir_recorded "$CONFIG_PARENT"
        local example csum=empty
        if example="$(find_config_example)"; then csum="$(sha_of_file "$example")"; fi
        record "config_dir_created $csum"
        run mkdir "$CONFIG_DIR"
        if [ "$csum" != empty ]; then
            run cp "$example" "$CONFIG_DIR/init.lua"
        else
            warn "init.lua.example not found; leaving $(tilde "$CONFIG_DIR") empty"
        fi
    fi

    step launchagent_plist "writing $(tilde "$AGENT_PLIST")"
    mkdir_recorded "$(dirname "$AGENT_PLIST")"
    if [ -e "$AGENT_PLIST" ] || [ -L "$AGENT_PLIST" ]; then
        warn "$(tilde "$AGENT_PLIST") exists; moving it aside (restored on uninstall)"
        record "backup launchagent"
        run mv "$AGENT_PLIST" "$BACKUP_DIR/launchagent"
    fi
    record "agent_plist_created"
    write_file "$AGENT_PLIST" "$(agent_plist_xml)"
    if ! is_dry; then "$PLUTIL" -lint -s "$AGENT_PLIST"; fi

    step accessibility "resetting Accessibility permission for $BUNDLE_ID"
    record "tcc_reset"
    run "$TCCUTIL" reset Accessibility "$BUNDLE_ID"

    step launchagent_load "loading the LaunchAgent (starts $APP_NAME)"
    if ! is_dry && "$LAUNCHCTL" print "$AGENT_TARGET" >/dev/null 2>&1; then
        warn "$AGENT_TARGET was already loaded; reloading it"
        run "$LAUNCHCTL" bootout "$AGENT_TARGET" || true
    fi
    record "launchagent_loaded"
    run "$LAUNCHCTL" bootstrap "gui/$UID_VAL" "$AGENT_PLIST"

    step open_settings "opening System Settings ▸ Privacy & Security ▸ Accessibility"
    run "$OPEN" "$ACCESSIBILITY_URL" || warn "could not open System Settings"

    step done "finished"
    record "install_complete"
    if is_dry; then
        info "dry run: nothing was changed"
    else
        ok "hyprMac installed. Enable it under Accessibility, then use ⌥1–9 / ⌥⇧1–9."
        info "undo everything with 'make uninstall' (record: $(tilde "$MANIFEST"))"
    fi
    local n
    for n in ${INSTALL_NOTES[@]+"${INSTALL_NOTES[@]}"}; do
        printf '%snote:%s %s\n' "$C_YELLOW" "$C_RESET" "$n"
    done
}

if [ -f "$VERIFY_FAILED" ]; then
    die "the last uninstall did not verify (state in $(tilde "$VERIFY_DIR")); fix it and run 'make verify-rollback' first"
fi
if [ -f "$JOURNAL" ]; then
    die "an earlier uninstall did not finish; run 'make uninstall' to complete it first"
fi
if [ -f "$MANIFEST" ]; then
    do_upgrade
else
    do_install
fi
