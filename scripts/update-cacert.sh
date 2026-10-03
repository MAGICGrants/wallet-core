#!/usr/bin/env bash
#
# Refreshes packages/wallet_infra/assets/cacert.pem, the CA set every TLS
# connection to a Monero server is verified against, from curl's extraction of
# Mozilla's root store (https://curl.se/docs/caextract.html).
#
# The download is checked against the SHA-256 curl publishes beside it. Review
# the diff before committing: roots Mozilla removed disappear here too.
set -euo pipefail

DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packages/wallet_infra/assets/cacert.pem"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL --proto '=https' --tlsv1.2 https://curl.se/ca/cacert.pem -o "$WORK/cacert.pem"
curl -fsSL --proto '=https' --tlsv1.2 https://curl.se/ca/cacert.pem.sha256 -o "$WORK/cacert.pem.sha256"

expected="$(awk '{print $1}' "$WORK/cacert.pem.sha256")"
if command -v sha256sum >/dev/null; then
  actual="$(sha256sum "$WORK/cacert.pem" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$WORK/cacert.pem" | awk '{print $1}')"
fi
if [ "$expected" != "$actual" ]; then
  echo "checksum mismatch: expected $expected, got $actual" >&2
  exit 1
fi

count="$(grep -c 'BEGIN CERTIFICATE' "$WORK/cacert.pem")"
if [ "$count" -lt 100 ]; then
  echo "only $count certificates; refusing to replace the bundle" >&2
  exit 1
fi

cp "$WORK/cacert.pem" "$DEST"
grep -m1 'Certificate data from Mozilla as of' "$DEST"
echo "$count certificates written to $DEST"
