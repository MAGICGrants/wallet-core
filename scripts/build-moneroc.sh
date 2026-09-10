#!/usr/bin/env bash
#
# Build monero_c's wallet2_api_c library for one target, at the FIXED
# path /tmp/monero_c.
#
# Args:
#   $1  target (e.g. aarch64-linux-android, x86_64-linux-gnu, x86_64-w64-mingw32)
#   $2  clone source (default: the local ./monero_c submodule; CI passes the remote URL)
#
# Run from the CONSUMING APP's repo root — it reads that app's pubspec.lock,
# which is the authority for which monero_c commit gets built. `reproducible.patch`
# is resolved next to this script, so the script works whether it lives in the
# app repo (historic) or in the magic-wallet-core submodule (current).
#
# Output: /tmp/monero_c/monero_libwallet2_api_c/build/<target>/libwallet2_api_c.{so,dll}
#
set -euo pipefail

TARGET="${1:?usage: build-moneroc.sh <target> [clone-source]}"
SRC="${2:-monero_c}"
REPO="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The monero package may be a direct dependency of the app or come in
# transitively via wallet_monero; either way pub writes one `monero:` entry
# into the app's lockfile, so this lookup is unaffected by the migration.
COMMIT=$(awk '/^  monero:/{f=1} f&&/resolved-ref:/{gsub(/"/,"",$2);print $2;exit}' "$REPO/pubspec.lock")
[ -n "$COMMIT" ] || { echo "no monero resolved-ref in $REPO/pubspec.lock" >&2; exit 1; }

# never create $HOME/.gitconfig (fdroiddata CI symlinks it per build)
export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-/tmp/magic-wallet-gitconfig}"
git config --global --add safe.directory '*'
git config --global user.name 'MAGIC Grants'
git config --global user.email 'info@magicgrants.org'

rm -rf /tmp/monero_c
git clone "$SRC" /tmp/monero_c
git -C /tmp/monero_c checkout "$COMMIT"
git -C /tmp/monero_c submodule update --init --recursive --force

cd /tmp/monero_c
# Pin the git-am committer date (baked into Monero's version string) + __DATE__/__TIME__.
export SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
export GIT_COMMITTER_DATE="@$SOURCE_DATE_EPOCH"
./apply_patches.sh monero
patch -p1 < "$SCRIPT_DIR/reproducible.patch"
unset MAKEFLAGS   # use make's classic pipe jobserver (from reproducible.patch), not the fifo one
./build_single.sh monero "$TARGET" -j"$(nproc)"
