#!/bin/bash
# Opt-in stable code-signing identity, so the Accessibility grant survives upgrades.
#
#   scripts/sign_identity.sh create [--dry-run]   make "hyprMac Local Signing" in the login keychain
#   scripts/sign_identity.sh remove [--dry-run]   delete it (only if this script made it)
#   scripts/sign_identity.sh status               print the identity's SHA-1, or "absent"
#   scripts/sign_identity.sh sign APP             sign APP with it, or ad-hoc when there is none
#
# `make sign-identity` / `make sign-identity-remove` call create / remove, and
# `make app` calls sign. SIGN_ADHOC=1 forces an ad-hoc signature (release builds).
#
# The certificate is self-signed and not trusted by macOS; it only gives the
# app a signature that is the same on every build. The private key is imported
# non-extractable, into the login keychain only. When hyprMac is installed,
# `create` records that in the install manifest so `make uninstall` removes the
# identity again; an identity that existed before install is never removed.
# Every system command goes through a variable (SECURITY, CODESIGN, OPENSSL), so
# the sandbox tests use shims and never touch a real keychain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"
[ $# -eq 0 ] || shift
case "$cmd" in -h | --help | help) usage; exit 0 ;; esac

app=""
for arg in "$@"; do
    case "$arg" in
        -n | --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; die "unknown argument: $arg" ;;
        *) if [ "$cmd" = sign ] && [ -z "$app" ]; then app="$arg"; else usage >&2; die "unexpected argument: $arg"; fi ;;
    esac
done

# `sign` runs inside `make app`: keep it as plain as the old codesign line.
if [ "$cmd" != sign ] || [ "${HYPR_SANDBOX:-0}" = 1 ]; then sandbox_guard; fi
trap cleanup_tmp EXIT

case "$cmd" in
    create)
        sign_identity_create
        if [ "$SIGN_IDENTITY_NEW" = 1 ]; then
            if [ -f "$MANIFEST" ]; then
                record "signing_identity_created"
                info "hyprMac is installed: run 'make update' to sign the installed app with it (Accessibility needs one more grant, then it sticks)"
                info "'make uninstall' will remove the identity again"
            else
                info "next: 'make install' (or 'make update') signs the app with it"
            fi
            info "macOS may ask once for your login password when codesign first uses the key: choose Always Allow"
        fi
        ;;
    remove)
        rc=0
        sign_identity_delete || rc=$?
        [ "$rc" = 0 ] || exit 1
        ;;
    status)
        h="$(sign_identity_hash)"
        if [ -n "$h" ]; then echo "$h"; else echo absent; fi
        ;;
    sign)
        [ -n "$app" ] || { usage >&2; die "sign needs an app path"; }
        [ -e "$app" ] || die "no such app: $app"
        sign_app "$app"
        ;;
    *) usage >&2; die "unknown command: ${cmd:-<none>}" ;;
esac
