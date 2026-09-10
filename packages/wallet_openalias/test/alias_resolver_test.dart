import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_openalias/wallet_openalias.dart';

/// Where this package meets `wallet_domain`.
///
/// The record layer is covered by `openalias_records_test.dart` and the wallet
/// layer's own bounds by `wallet_domain/test/alias_test.dart`, and both suites
/// pass while saying opposite-sounding things: the record layer returns an
/// oversized address "verbatim for the caller to reject", and the wallet layer
/// rejects one supplied by a fake resolver. Neither exercises the pair.
///
/// That gap is exactly the seam this package exists to close. While the plugin
/// lived in two app repos, "the caller validates" was an assumption written down
/// in one repository about code in another, and the assumption was already
/// false in one of them, where the adapter reduced a record to a bare address.
void main() {
  setUp(() {
    WalletAppConfig.resetForTesting();
    WalletAppConfig.install(WalletAppConfig.spice);
    SharedPreferencesService.store = MemoryPreferenceStore();
  });

  tearDown(() {
    CryptoWallet.resetInjectablesForTesting();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    TorSettingsService.sharedInstance.resetForTesting();
  });

  group('resolvedAliasFrom', () {
    test('carries the display fields a v1 record publishes', () {
      final result = _resolve(
        oa1: [
          'oa1:xmr recipient_address=$_xmrAddress; recipient_name=Donate; '
              'tx_description=Coffee; tx_amount=1.25; tx_payment_id=abc123;',
        ],
      );

      final alias = resolvedAliasFrom(result);
      expect(alias.address, _xmrAddress);
      expect(alias.recipientName, 'Donate');
      expect(alias.description, 'Coffee');
      // An exact decimal string, kept as text. The send path converts it with
      // `decimalToBaseUnits` rather than parsing it to a double.
      expect(alias.requestedAmount, '1.25');
      expect(alias.memo, 'abc123');
      expect(alias.alternatives, isEmpty);
    });

    test('takes a v2 recipient name from the metadata record', () {
      final result = _resolve(
        payment: ['oa_version=2; network=xmr; asset=xmr; address=$_xmrAddress;'],
        metadata: ['oa_version=2; name=Alice; description=Tips;'],
      );

      // v2 moves the name off the payment record, so a resolver that only read
      // the payment record would show the user nothing about who they are paying
      //, which is the entire reason to prefer an alias to a pasted address.
      final alias = resolvedAliasFrom(result);
      expect(alias.recipientName, 'Alice');
      expect(alias.description, 'Tips');
    });

    test('keeps the alternatives in priority order and does not nest them', () {
      final result = _resolve(
        payment: [
          'oa_version=2; network=xmr; asset=xmr; address=${_xmrAddress}c; priority=30;',
          'oa_version=2; network=xmr; asset=xmr; address=$_xmrAddress; priority=10;',
          'oa_version=2; network=xmr; asset=xmr; address=${_xmrAddress}b; priority=20;',
        ],
      );

      final alias = resolvedAliasFrom(result);
      expect(alias.address, _xmrAddress);
      expect(alias.alternatives.map((a) => a.address), ['${_xmrAddress}b', '${_xmrAddress}c']);
      expect(
        alias.alternatives.every((a) => a.alternatives.isEmpty),
        isTrue,
        reason: 'a nested tier would be one validation pass short of the send screen',
      );
    });
  });

  // `resolveAlias` refuses to call the resolver at all without a proxy, and
  // asserts that on the resolver never having run rather than on the throw; one
  // that ran and then failed has already handed the counterparty's domain, and
  // the IP asking for it, to every DNS hop in between. `external` mode supplies
  // a port without needing a live Tor.
  Future<void> torAvailable() =>
      TorSettingsService.sharedInstance.save(torMode: TorMode.external, socksPort: '9050');

  group('composed with CryptoWallet.resolveAlias', () {
    test('a hostile display name is dropped, and the payment survives', () async {
      await torAvailable();
      final wallet = _AliasOnlyWallet();
      // A right-to-left override reorders what is rendered, so a name can
      // display as something other than what it is; on the one screen where
      // that pays.
      //
      // Written as a `\u` escape, not a literal. `alias_test.dart` records the
      // same lesson: a file about invisible-character attacks that contains the
      // characters is a file the analyzer flags and `grep` may treat as binary.
      const bidiOverride = '\u202E';
      CryptoWallet.aliasResolver = _resolverReturning(
        _resolve(
          payment: ['oa_version=2; network=xmr; asset=xmr; address=$_xmrAddress;'],
          metadata: ['oa_version=2; name=Ali${bidiOverride}ec;'],
        ),
      );

      final resolved = await wallet.resolveAlias('donate@example.com');
      expect(resolved, isNotNull);
      expect(resolved!.address, _xmrAddress);
      expect(
        resolved.recipientName,
        isNull,
        reason: 'dropped, not truncated — a mangled name still reads as the recipient\'s own words',
      );
    });

    test('an address this coin cannot pay never reaches the caller', () async {
      await torAvailable();
      final wallet = _AliasOnlyWallet();
      CryptoWallet.aliasResolver = _resolverReturning(
        _resolve(oa1: ['oa1:xmr recipient_address=not-a-monero-address;']),
      );

      // The record layer hands back whatever the zone published. This is the
      // half that decides it is unpayable, and the two only line up if the
      // adapter passes the address through unaltered.
      expect(await wallet.resolveAlias('donate@example.com'), isNull);
    });

    test('an oversized address is rejected before the coin validator sees it', () async {
      await torAvailable();
      final wallet = _AliasOnlyWallet();
      CryptoWallet.aliasResolver = _resolverReturning(
        _resolve(oa1: ['oa1:xmr recipient_address=${'5' * 4096};']),
      );

      expect(await wallet.resolveAlias('donate@example.com'), isNull);
      expect(
        wallet.validatedLengths,
        everyElement(lessThanOrEqualTo(AliasLimits.maxAddressLength)),
        reason: 'the bounds check runs first, so a subclass regex never meets a 4 KB string',
      );
    });

    test('a bad alternative is dropped without losing the primary', () async {
      await torAvailable();
      final wallet = _AliasOnlyWallet();
      CryptoWallet.aliasResolver = _resolverReturning(
        _resolve(
          payment: [
            'oa_version=2; network=xmr; asset=xmr; address=$_xmrAddress; priority=1;',
            'oa_version=2; network=xmr; asset=xmr; address=nonsense; priority=2;',
          ],
        ),
      );

      final resolved = await wallet.resolveAlias('donate@example.com');
      expect(resolved!.address, _xmrAddress);
      expect(resolved.alternatives, isEmpty);
    });
  });

  group('exception identity', () {
    test('normalizeAlias throws the type wallet_domain declares', () {
      // Two same-named classes would not fail loudly: an app catching
      // `wallet_domain`'s would simply not catch the plugin's, and the send
      // screen would show a DNS error for a correctly typed address.
      Object? thrown;
      try {
        normalizeAlias('4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44');
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<NotAnAliasException>());
      expect(
        thrown,
        isNot(isA<OpenAliasException>()),
        reason: 'kept separate so `on OpenAliasException` cannot swallow "that is an address"',
      );
    });
  });
}

/// A valid mainnet Monero address, so the coin validator has something real to
/// accept. Never used to hold value.
const _xmrAddress =
    '44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A';

/// Builds an [OpenAliasResult] the way a live lookup would, so the tests
/// exercise the real selection path rather than a hand-built record.
OpenAliasResult _resolve({
  List<String> payment = const [],
  List<String> metadata = const [],
  List<String> oa1 = const [],
}) => resolveFromLookups(
  OpenAliasLookups(paymentRecords: payment, metadataRecords: metadata, oa1Records: oa1),
  alias: 'donate.example.com',
  network: 'xmr',
  asset: 'xmr',
  nativeAsset: 'xmr',
);

AliasResolver _resolverReturning(OpenAliasResult result) =>
    ({
      required String alias,
      required String network,
      required String asset,
      required int socksPort,
      String? nativeAsset,
    }) async => resolvedAliasFrom(result);

/// The smallest wallet that can answer an alias query: a real [CryptoWallet], so
/// the bounds, sanitization and address validation under test are the shipping
/// ones rather than a restatement of them.
class _AliasOnlyWallet extends CryptoWallet {
  /// Every address handed to [isAddressValid], to check what the bounds check
  /// let through.
  final List<int> validatedLengths = [];

  @override
  String get coinSymbol => 'XMR';
  @override
  String get blockchainName => 'Monero';
  @override
  String get iconAsset => '';
  @override
  int get decimals => 12;
  @override
  int get smallerDigits => 9;
  @override
  int get requiredConfirmations => 10;
  @override
  String get connectionTypeName => 'test';
  @override
  String get connectionAddressExample => '';
  @override
  String get aliasNetwork => 'xmr';

  @override
  bool isAddressValid(String address) {
    validatedLengths.add(address.length);
    return RegExp(r'^[48][0-9A-Za-z]{94}$').hasMatch(address);
  }

  @override
  String getPrimaryAddress() => _xmrAddress;

  // Nothing below is reachable from resolveAlias.
  @override
  Future<bool> hasExistingWallet() async => false;
  @override
  Future<void> openExisting({required String password}) async {}
  @override
  Future<void> restoreFromSeed({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  }) async {}
  @override
  Future<bool> store() async => false;
  @override
  Future<void> deleteFiles() async {}
  @override
  Future<void> connectToDaemonImpl({required String address, String? proxyPort}) async {}
  @override
  Future<void> testConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
    String connectionType = '',
  }) async {}
  @override
  Future<bool> getIsConnected() async => false;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> loadIsSynced() async {}
  @override
  Future<void> loadSyncedHeight() async {}
  @override
  Future<void> loadUnlockedBalance() async {}
  @override
  Future<void> loadTotalBalance() async {}
  @override
  Future<int> getCurrentHeight() async => 0;
  @override
  Future<int> getRestoreHeight() async => 0;
  @override
  List<TxDetails> readTxHistory() => const [];
  @override
  Future<PendingTransaction> createTx(
    String destinationAddress,
    BigInt amountBaseUnits,
    bool isSweepAll, {
    int priority = 0,
  }) => throw UnimplementedError();
  @override
  Future<void> commitTx(PendingTransaction tx, String destinationAddress) async {}
}
