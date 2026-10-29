#!/bin/sh
# install-on-device.sh — install node-ios on a jailbroken (rootless) iOS device.
#
# Run ON the device (iPhone/iPad, arm64, iOS 15+, Dopamine or palera1n rootless):
#
#   curl -fsSL https://raw.githubusercontent.com/repos1tory/node-ios/main/scripts/install-on-device.sh | sh
#
# or from a checkout:
#
#   sh scripts/install-on-device.sh
#
# What it does:
#   1. downloads the verified Node 22.19.0 binary + entitlements from the GitHub release
#   2. signs the binary with ldid (dynamic-codesigning + extended virtual addressing)
#   3. installs it to $PREFIX/usr/lib/node-ios/node
#   4. writes a $PREFIX/usr/bin/node shim that ALWAYS passes the required flags:
#        --predictable --single-threaded        (safe process-wide mprotect W^X JIT flip)
#        --disable-wasm-trap-handler            (no 10GB guarded wasm reservation; iOS VA cap)
#
# Requires: sudo (device is rootless; /var/jb is root-owned), ldid, curl.
#
# Env overrides: PREFIX (default /var/jb), SUDO (default "sudo"),
#   NODE_VERSION (default 22.19.0), NODE_RELEASE_TAG (default v22.19.0-ios1)
set -eu
umask 022

PREFIX="${PREFIX:-/var/jb}"
SUDO="${SUDO:-sudo}"
NODE_VERSION="${NODE_VERSION:-22.19.0}"
NODE_RELEASE_TAG="${NODE_RELEASE_TAG:-${NODE_TAG:-v22.19.0-ios1}}"
REPO="${REPO:-repos1tory/node-ios}"
BIN="node-${NODE_VERSION}-iphoneos-arm64"
BASE_URL="https://github.com/${REPO}/releases/download/${NODE_RELEASE_TAG}"

say()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- sanity checks -----------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || fail "this installer is for iOS (Darwin), got: $(uname -s)"

if [ ! -d "$PREFIX" ]; then
  fail "no $PREFIX found — this looks like a rootful or non-jailbroken setup.
     Rootless jailbreaks (Dopamine, palera1n rootless) mount the bootstrap at /var/jb."
fi

if ! command -v ldid >/dev/null 2>&1; then
  PATH="$PREFIX/usr/bin:$PATH"
  command -v ldid >/dev/null 2>&1 || fail "ldid not found. Install it from Sileo/Zebra (Procursus has it)."
fi

command -v curl >/dev/null 2>&1 || fail "curl not found."

# --- download ----------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "==> downloading $BIN"
curl -fL --progress-bar -o "$TMP/node" "${BASE_URL}/${BIN}"
curl -fsSL -o "$TMP/entitlements.plist" "${BASE_URL}/entitlements.plist"

# --- sign --------------------------------------------------------------------
say "==> signing with entitlements (dynamic-codesigning, extended virtual addressing)"
ldid -S"$TMP/entitlements.plist" "$TMP/node"
chmod 755 "$TMP/node"

# --- install -----------------------------------------------------------------
say "==> installing to $PREFIX/usr/lib/node-ios/"
$SUDO mkdir -p "$PREFIX/usr/lib/node-ios" "$PREFIX/usr/bin"
$SUDO chmod 755 "$PREFIX/usr/lib/node-ios" "$PREFIX/usr/bin"
$SUDO cp "$TMP/node" "$PREFIX/usr/lib/node-ios/node"
$SUDO cp "$TMP/entitlements.plist" "$PREFIX/usr/lib/node-ios/entitlements.plist"
$SUDO chmod 755 "$PREFIX/usr/lib/node-ios/node"
$SUDO chmod 644 "$PREFIX/usr/lib/node-ios/entitlements.plist"

say "==> writing $PREFIX/usr/bin/node shim"
# NOTE: shebang is /var/jb/bin/sh, not /bin/sh -- rootless jailbreaks have no /bin/sh.
$SUDO tee "$PREFIX/usr/bin/node" >/dev/null <<SHIM
#!/var/jb/bin/sh
# node-ios shim: passes the flags required by the mprotect W^X JIT patch and
# avoids V8's 10GB guarded wasm-memory reservation (which iOS's VA cap rejects).
exec "$PREFIX/usr/lib/node-ios/node" --predictable --single-threaded --disable-wasm-trap-handler "\$@"
SHIM
$SUDO chmod 755 "$PREFIX/usr/bin/node"

# --- verify ------------------------------------------------------------------
say "==> verifying"
"$PREFIX/usr/bin/node" --version
say ""
say "Done. node $( "$PREFIX/usr/bin/node" --version ) installed."
say "Try:  node -e 'const m=new WebAssembly.Memory({initial:1}); console.log(\"wasm memory OK\")'"
