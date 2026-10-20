#!/bin/sh
# libfido2's reading for the hmac-secret parity test (lib/hmac_parity.dart):
# the hmac-secret a credential gives over the fixed test salt, through
# libfido2's own tools, the same library FHSE's device.c and the Linux backend
# use. Compare its "hmac-secret:" line with the app's for the same credential
# (debug builds: Settings > Advanced Security > hmac-secret parity test). They
# must match byte for byte. See test/README.md.
#
# Usage:
#   sh tool/hmac_parity.sh enroll [device]               create a test credential, then read it
#   sh tool/hmac_parity.sh assert <credential> [device]  read an existing credential
#
# <credential> is base64, as the app prints it (URL-safe or unpadded is fine).
# [device] defaults to the first key `fido2-token -L` lists. libfido2's tools
# ask for the PIN on the terminal; it never passes through this script. The
# key needs a PIN (as FHSE does): set one with `fido2-token -S <device>`.
#
# Needs libfido2's tools (fido2-token, fido2-cred, fido2-assert), base64, od,
# and openssl for the salt's self-check.
set -eu

RP_ID='fhse:encryption'
USER_NAME='FHSE Encryption'
SALT_LABEL='FHSE hmac-secret parity test v1'
# SHA-256 of SALT_LABEL; the same constant as HmacParity.saltBase64.
SALT_B64='gTFyG6+HfGxYT7lGePmQn/fqYUkoYcGNzfxWPW3nLkk='
# SHA-256 of {0x01}: the client data FHSE's device.c and the mobile backends
# use. It goes into the signature only, never into the hmac-secret.
CDH_B64='S/USLzRFVMU73i67jNK349FgCtYxw4Wl18ziPHeFRZo='
CRED_PROTECT_UV_REQUIRED=3

die() {
  echo "hmac_parity: $*" >&2
  exit 1
}

usage() {
  sed -n '9,11p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

first_device() {
  fido2-token -L | sed -n '1s/: .*//p'
}

# Standard, padded base64, whatever form the credential id was pasted in.
normalize_b64() {
  b64=$(printf '%s' "$1" | tr -d ' \n\r\t' | tr -- '-_' '+/')
  while [ $((${#b64} % 4)) -ne 0 ]; do b64="$b64="; done
  printf '%s' "$b64"
}

# Whether the UV flag is set in base64, CBOR-wrapped authenticator data as
# fido2-assert prints it: a byte string holding rpIdHash (32), flags (1), ...
uv_flag_set() {
  # shellcheck disable=SC2046 # one field per byte, on purpose
  set -- $(printf '%s' "$1" | base64 --decode | od -An -v -tu1)
  [ $# -ge 1 ] || return 1
  case $1 in
    88) shift 2 ;; # 0x58: one-byte length
    89) shift 3 ;; # 0x59: two-byte length
    *)
      { [ "$1" -ge 64 ] && [ "$1" -le 87 ]; } || return 1
      shift 1
      ;;
  esac
  [ $# -gt 32 ] || return 1
  shift 32
  [ $(($1 & 4)) -ne 0 ]
}

read_hmac() {
  cred_id=$1
  device=$2
  out=$(printf '%s\n%s\n%s\n%s\n' "$CDH_B64" "$RP_ID" "$cred_id" "$SALT_B64" |
    fido2-assert -G -h -v "$device") || die "fido2-assert failed"
  authdata=$(printf '%s\n' "$out" | sed -n 3p)
  hmac=$(printf '%s\n' "$out" | sed -n '$p')
  # Without user verification the key answers from its other secret
  # (CredRandomWithoutUV), which FHSE never uses.
  uv_flag_set "$authdata" || die "the key did not verify the user for this assertion"
  [ "$(printf '%s' "$hmac" | base64 --decode | wc -c | tr -d ' ')" = 32 ] ||
    die "the hmac-secret is not 32 bytes"
  printf 'backend: libfido2 (fido2-assert)\nrp: %s\nsalt: %s\ncredential: %s\nhmac-secret: %s\n' \
    "$RP_ID" "$SALT_B64" "$cred_id" "$hmac"
}

enroll() {
  device=$1
  user_id=$(head -c 64 /dev/urandom | base64 | tr -d '\n')
  # No -v here: fido2-cred -v first asks the key to verify the user itself,
  # before any PIN, and a key without a fingerprint reader refuses that
  # (FIDO_ERR_UNSUPPORTED_OPTION). Without it, a key with a PIN answers
  # PIN_REQUIRED and fido2-cred asks for the PIN. Whether the user was verified
  # at creation does not change the hmac-secret; the assertion below must be.
  cred=$(printf '%s\n%s\n%s\n%s\n' "$CDH_B64" "$RP_ID" "$USER_NAME" "$user_id" |
    fido2-cred -M -h -c "$CRED_PROTECT_UV_REQUIRED" "$device" es256) || die "fido2-cred failed"
  cred_id=$(printf '%s\n' "$cred" | sed -n 5p)
  [ -n "$cred_id" ] || die "fido2-cred printed no credential id"
  # As the app's enrollment checks: hmac-secret on and credProtect 3, signed
  # by the key. Only a warning: some attestation formats libfido2 cannot
  # verify, and neither changes the hmac-secret.
  if ! printf '%s\n' "$cred" | fido2-cred -V -h -c "$CRED_PROTECT_UV_REQUIRED" es256 >/dev/null 2>&1; then
    echo "hmac_parity: warning: libfido2 could not verify the new credential's attestation" >&2
  fi
  echo "hmac_parity: created a test credential under $RP_ID" >&2
  read_hmac "$cred_id" "$device"
}

[ $# -ge 1 ] || usage
if command -v openssl >/dev/null 2>&1; then
  [ "$(printf '%s' "$SALT_LABEL" | openssl dgst -sha256 -binary | base64)" = "$SALT_B64" ] ||
    die "SALT_B64 is not the SHA-256 of SALT_LABEL"
fi

case $1 in
  enroll)
    [ $# -le 2 ] || usage
    device=${2:-$(first_device)}
    [ -n "$device" ] || die "no FIDO2 device found (fido2-token -L)"
    enroll "$device"
    ;;
  assert)
    { [ $# -ge 2 ] && [ $# -le 3 ]; } || usage
    device=${3:-$(first_device)}
    [ -n "$device" ] || die "no FIDO2 device found (fido2-token -L)"
    read_hmac "$(normalize_b64 "$2")" "$device"
    ;;
  *) usage ;;
esac
