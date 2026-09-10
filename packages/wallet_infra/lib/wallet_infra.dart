/// Transport, storage and logging primitives with no coin or app knowledge.
///
/// Covers SOCKS/Tor transport, HTTP over SOCKS, file and preference storage,
/// secure storage, at-rest encryption, logging and a few UI helpers. Nothing
/// here knows about a coin or a specific app.
library;

export 'src/crypto/hashes.dart';
export 'src/crypto/pbkdf2.dart';
export 'src/crypto/wallet_file_crypto.dart';
export 'src/log_files.dart';
export 'src/logging.dart';
export 'src/net/bounded_reader.dart';
export 'src/net/cacert.dart';
export 'src/net/endpoint_security.dart';
export 'src/net/socks_http.dart';
export 'src/net/socks_socket.dart';
export 'src/paths.dart';
export 'src/settings/language_model.dart';
export 'src/settings/theme_model.dart';
export 'src/storage/preferences.dart';
export 'src/storage/secure_storage.dart';
export 'src/storage/wallet_password.dart';
export 'src/tor/tor_service.dart';
export 'src/tor/tor_settings_service.dart';
export 'src/ui/biometric_auth.dart';
export 'src/ui/notification_service.dart';
export 'src/ui/secure_clipboard.dart';
export 'src/ui/secure_screen.dart';
