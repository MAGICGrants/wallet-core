import 'package:http/http.dart' as http;

/// An [http.Client] that refuses all network I/O.
///
/// Backs the `Web3Client` used only to sign transactions. If `web3dart` ever
/// performs a request on it; because a transaction field was left for it to
/// fill in; this fails loudly instead of silently egressing over clearnet and
/// bypassing the Tor/SOCKS routing every other request in this package uses.
class OfflineSigningClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // The URL is our own configured endpoint, not a counterparty, so naming it
    // is the same disclosure as logging the connection address.
    throw StateError('Offline signing client must not make network requests (${request.url}).');
  }
}
