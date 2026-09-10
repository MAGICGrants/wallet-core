#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive DEBCONF_NOWARNINGS=yes
apt update
apt install -y apt-utils
apt install -y build-essential pkg-config autoconf libtool ccache make cmake gcc g++ git curl \
  lbzip2 gperf unzip python-is-python3 llvm gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
apt install -y libtinfo5 2>/dev/null || echo "libtinfo5 unavailable (trixie) — skipping"

update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

export GIT_CONFIG_GLOBAL=/tmp/magic-wallet-gitconfig # never create $HOME/.gitconfig (fdroiddata CI symlinks it per build)
git config --global --add safe.directory '*'
git config --global user.email "info@magicgrants.org"
git config --global user.name "MAGIC Grants"

REPO="$PWD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clone source is read from the lockfile rather than hardcoded.
#
# This used to be a literal https://github.com/vtnerd/monero_c.git while the
# commit came from pubspec.lock — fine only while the pin happened to live in
# that fork. It does not: the fee-estimation pin (D1) is
# magicgrants/monero_c@c74f8df, which does not exist in vtnerd's repo, so the
# hardcoded URL would fail at `git checkout` the moment the pin moved. Reading
# both url and ref from the same lockfile entry keeps them consistent forever,
# including when the pin moves back to vtnerd after upstreaming.
URL=$(awk '/^  monero:/{f=1} f&&/^      url:/{gsub(/"/,"",$2);print $2;exit}' "$REPO/pubspec.lock")
[ -n "$URL" ] || { echo "no monero url in $REPO/pubspec.lock" >&2; exit 1; }
echo "monero_c clone source (from pubspec.lock): $URL"

# Shared reproducible monero_c build — identical code path to the F-Droid recipe, so the
# committed .so matches F-Droid's rebuild. Clones from the remote (this CI checkout has no
# populated submodule); then symlink output where build-monero-c.yml's cp step expects it.
rm -rf "$REPO/monero_c"
bash "$SCRIPT_DIR/build-moneroc.sh" "$TARGET_ARCH" "$URL"
ln -s /tmp/monero_c "$REPO/monero_c"