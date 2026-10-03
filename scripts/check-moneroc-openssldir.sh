#!/usr/bin/env bash
#
# Fails when a monero_c library's OpenSSL would read certificates or
# openssl.cnf from a path under the build tree. CI builds in /tmp, so such a
# path names a directory any local user can create on the machine the wallet
# runs on, and whoever creates it first decides which CAs the wallet trusts.
#
# Usage: check-moneroc-openssldir.sh <library>...
set -euo pipefail

status=0
for lib in "$@"; do
  if grep -aqE 'contrib/depends/[A-Za-z0-9_.-]+/etc/openssl' "$lib"; then
    echo "$lib: OpenSSL's default paths point into the build tree:" >&2
    grep -aoE '/[A-Za-z0-9_./-]*contrib/depends/[A-Za-z0-9_.-]+/etc/openssl[A-Za-z0-9_./-]*' "$lib" | sort -u | sed 's/^/  /' >&2
    status=1
  elif ! grep -aqF '/etc/ssl/cert.pem' "$lib"; then
    # OpenSSL compiles OPENSSLDIR/cert.pem in as its default CA file.
    echo "$lib: OPENSSLDIR is not /etc/ssl (see monero_c contrib/depends/packages/openssl.mk)" >&2
    status=1
  else
    echo "$lib: OpenSSL defaults to /etc/ssl"
  fi
done
exit $status
