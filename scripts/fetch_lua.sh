#!/bin/bash
# scripts/fetch_lua.sh — Download and verify Lua 5.4.7 for hyprMac
#
# Fetches the official Lua 5.4.7 release from lua.org, cryptographically
# verifies its SHA256 checksum against the known official release hash,
# and stages the C source and headers into third_party/lua-5.4.7/.
#
# Standalone CLI files (lua.c and luac.c) are excluded so that only the
# embeddable library is compiled into libhyprcore.a.
set -euo pipefail

LUA_VERSION="5.4.7"
LUA_SHA256="9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30"
LUA_URL="https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"

DEST_DIR="${1:-third_party/lua-${LUA_VERSION}}"

# Fast-path: already fetched and complete.
if [ -f "${DEST_DIR}/.fetched" ] && [ -f "${DEST_DIR}/lua.h" ]; then
    exit 0
fi

# Ensure required macOS host tools are available.
for cmd in curl shasum tar; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "error: required command '${cmd}' not found in PATH" >&2
        exit 1
    fi
done

echo "==> Fetching Lua ${LUA_VERSION} from ${LUA_URL}..."
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hyprmac-lua.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

TARBALL="${TMP_DIR}/lua-${LUA_VERSION}.tar.gz"
if ! curl --retry 3 --retry-delay 1 --retry-connrefused -fsSL "${LUA_URL}" -o "${TARBALL}"; then
    echo "error: failed to download Lua from ${LUA_URL}" >&2
    exit 1
fi

echo "==> Verifying SHA256 checksum..."
ACTUAL_SHA="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
if [ "${ACTUAL_SHA}" != "${LUA_SHA256}" ]; then
    echo "error: SHA256 checksum mismatch for Lua ${LUA_VERSION}!" >&2
    echo "  expected: ${LUA_SHA256}" >&2
    echo "  actual:   ${ACTUAL_SHA}" >&2
    exit 1
fi

echo "==> Extracting and staging Lua ${LUA_VERSION}..."
EXTRACT_DIR="${TMP_DIR}/extract"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${TARBALL}" -C "${EXTRACT_DIR}"

STAGE_DIR="${TMP_DIR}/staged"
mkdir -p "${STAGE_DIR}"
cp "${EXTRACT_DIR}/lua-${LUA_VERSION}/README" "${STAGE_DIR}/"
cp ${EXTRACT_DIR}/lua-${LUA_VERSION}/src/*.[ch] "${STAGE_DIR}/"
cp "${EXTRACT_DIR}/lua-${LUA_VERSION}/src/lua.hpp" "${STAGE_DIR}/" 2>/dev/null || true

# Strip CLI and compiler mains (libhyprcore embed only)
rm -f "${STAGE_DIR}/lua.c" "${STAGE_DIR}/luac.c"

# Mark as completely fetched
touch "${STAGE_DIR}/.fetched"

# Atomically install into destination
mkdir -p "$(dirname "${DEST_DIR}")"
rm -rf "${DEST_DIR}"
mv "${STAGE_DIR}" "${DEST_DIR}"

echo "==> Lua ${LUA_VERSION} successfully installed into ${DEST_DIR}"
