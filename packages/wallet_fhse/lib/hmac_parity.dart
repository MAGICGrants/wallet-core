/// Developer tooling: checks on real keys that every platform's backend gets
/// the same hmac-secret from one credential and salt. Debug builds reach
/// [HmacParityScreen] from Advanced Security; `tool/hmac_parity.sh` gives
/// libfido2's reading. See test/README.md.
library;

export 'src/parity/hmac_parity.dart';
export 'src/ui/hmac_parity_screen.dart';
