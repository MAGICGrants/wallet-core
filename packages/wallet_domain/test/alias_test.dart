import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

/// `CryptoWallet.resolveAlias`; the `resolveOpenAlias` path, which had no
/// test at all.
///
/// An alias lookup is the moment the wallet learns who the user is about to pay,
/// and it is the only outbound request in this class made on the *recipient's*
/// name rather than the user's own server. Two properties carry the file:
///
///   - **the query never leaves without Tor.** The domain being resolved is the
///     counterparty. A resolver call that fell back to an unproxied lookup would
///     hand that name, and the IP asking for it, to every DNS hop in between.
///   - **the answer is validated before it is payable.** The address arrives
///     from the recipient's DNS; a hostile or hijacked record returning an
///     address for a different chain must not reach the send screen.

void main() {
  late Directory tmp;
  late MemoryLogSink logs;

  /// Arguments each resolver invocation received.
  late List<({String alias, String network, String asset, String? nativeAsset, int socksPort})>
  calls;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('alias');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    logs = MemoryLogSink();
    WalletLog.sink = logs;
    WalletLog.isVerbose = () async => true;
    calls = [];
  });

  tearDown(() {
    CryptoWallet.resetInjectablesForTesting();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    TorSettingsService.sharedInstance.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> logged() async {
    await Future<void>.delayed(Duration.zero);
    return logs.records.map((r) => r.line).join('\n');
  }

  /// Installs a resolver that records its arguments and returns [result].
  void installResolver({ResolvedAlias? result, Object? throws}) {
    CryptoWallet.aliasResolver =
        ({
          required String alias,
          required String network,
          required String asset,
          required int socksPort,
          String? nativeAsset,
        }) async {
          calls.add((
            alias: alias,
            network: network,
            asset: asset,
            nativeAsset: nativeAsset,
            socksPort: socksPort,
          ));
          if (throws != null) throw throws;
          return result;
        };
  }

  Future<void> torOnPort(String port) =>
      TorSettingsService.sharedInstance.save(torMode: TorMode.external, socksPort: port);
  Future<void> torUnavailable() =>
      TorSettingsService.sharedInstance.save(torMode: TorMode.disabled);

  const address = '4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  group('the query never leaves without Tor', () {
    test('no Tor proxy means the resolver is never called', () async {
      await torUnavailable();
      installResolver(result: const ResolvedAlias(address: address));
      final wallet = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(wallet.dispose);

      await expectLater(wallet.resolveAlias('donate.example.org'), throwsA(isA<Exception>()));

      // Throwing is not the assertion; the empty call list is. A resolver that
      // ran and then failed has already sent the recipient's domain in the
      // clear, and the user's IP with it.
      expect(calls, isEmpty);
      expect(await logged(), contains('Tor proxy unavailable'));
    });

    test('a resolver failure is logged and rethrown, not turned into "no record"', () async {
      await torOnPort('9150');
      installResolver(throws: Exception('DNSSEC chain is broken'));
      final wallet = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(wallet.dispose);

      // Rethrown rather than nulled: "the lookup failed" and "this alias has no
      // record" must not read the same. The resolver package logs nothing, so
      // this is the only place the reason is recorded.
      await expectLater(wallet.resolveAlias('donate.example.org'), throwsA(isA<Exception>()));

      final written = await logged();
      expect(written, contains('alias: resolve failed'));
      expect(written, contains('DNSSEC chain is broken'));
      expect(written, isNot(contains('donate.example.org')), reason: 'the payee is fingerprinted');
    });

    test('the proxy port reaches the resolver', () async {
      await torOnPort('9150');
      installResolver(result: const ResolvedAlias(address: address));
      final wallet = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(wallet.dispose);

      await wallet.resolveAlias('donate.example.org');

      expect(calls.single.socksPort, 9150);
    });
  });

  group('what the resolver is asked', () {
    test('network, asset and native asset are passed separately', () async {
      await torOnPort('9050');
      installResolver(result: const ResolvedAlias(address: address));
      // A token on a chain: OA2 network `eth`, asset `dai`, native `eth`.
      final dai = FakeAliasWallet('DAI', network: 'eth', asset: 'dai', native: 'eth');
      addTearDown(dai.dispose);

      await dai.resolveAlias('shop.example.org');

      // Collapsing these into one string is a v1 assumption: a v2 record that
      // omits `asset` denotes the *native* asset, so a resolver told only "dai"
      // cannot tell whether a bare record is payable.
      expect(calls.single.network, 'eth');
      expect(calls.single.asset, 'dai');
      expect(calls.single.nativeAsset, 'eth');
    });

    test('the alias is passed through verbatim', () async {
      await torOnPort('9050');
      installResolver(result: const ResolvedAlias(address: address));
      final wallet = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(wallet.dispose);

      await wallet.resolveAlias('someone@example.org');

      expect(calls.single.alias, 'someone@example.org');
    });
  });

  group('coins and resolvers that cannot answer', () {
    test('a coin with no alias network resolves nothing and asks nobody', () async {
      await torOnPort('9050');
      installResolver(result: const ResolvedAlias(address: address));
      final wallet = FakeWallet('BTC'); // aliasNetwork defaults to empty
      addTearDown(wallet.dispose);

      expect(await wallet.resolveAlias('donate.example.org'), isNull);
      expect(calls, isEmpty);
    });

    test('no resolver installed is null, not a crash', () async {
      await torOnPort('9050');
      final wallet = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(wallet.dispose);

      // The resolver is injected and this package does not import one, so the
      // core has to behave with none installed; an app that ships no alias
      // support, or one whose `main()` has not run yet.
      expect(await wallet.resolveAlias('donate.example.org'), isNull);
    });

    test('an alias that publishes nothing payable is null', () async {
      await torOnPort('9050');
      installResolver(result: null);
      final wallet = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(wallet.dispose);

      expect(await wallet.resolveAlias('donate.example.org'), isNull);
      expect(await logged(), contains('no payable record'));
    });

    test('a raw address surfaces as NotAnAliasException, not a DNS error', () async {
      await torOnPort('9050');
      installResolver(throws: const NotAnAliasException('4AAA...'));
      final wallet = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(wallet.dispose);

      // The send screen quietly treats the input as an address on this one.
      // Flattening it into a generic failure shows the user a DNS error for
      // something they typed correctly.
      await expectLater(wallet.resolveAlias('4AAA...'), throwsA(isA<NotAnAliasException>()));
    });

    test('a resolution failure propagates rather than reading as "no record"', () async {
      await torOnPort('9050');
      installResolver(throws: Exception('DNSSEC validation failed'));
      final wallet = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(wallet.dispose);

      // Null means "this alias has nothing for you" and the UI moves on.
      // A failed DNSSEC validation is not that, and must not look like it.
      await expectLater(wallet.resolveAlias('donate.example.org'), throwsA(isA<Exception>()));
    });
  });

  group('the answer is validated before it is payable', () {
    test('an address this coin cannot pay is refused', () async {
      await torOnPort('9050');
      installResolver(result: const ResolvedAlias(address: 'bc1qsomethingelse'));
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      // The address comes from the recipient's DNS. A hijacked or hostile
      // record handing back another chain's address must not reach the send
      // screen, where it would be one confirmation from an unrecoverable send.
      expect(await wallet.resolveAlias('donate.example.org'), isNull);
      expect(await logged(), contains('resolved address rejected'));
    });

    test('a valid record comes back whole, not flattened to an address', () async {
      await torOnPort('9050');
      installResolver(
        result: const ResolvedAlias(
          address: address,
          recipientName: 'Example Charity',
          description: 'General fund',
          requestedAmount: '1.5',
          memo: 'thanks',
        ),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      final resolved = await wallet.resolveAlias('donate.example.org');

      // Showing the name and description back before the user confirms is the
      // defence against a lookalike alias; a v1-shaped return throws it away.
      expect(resolved!.address, address);
      expect(resolved.recipientName, 'Example Charity');
      expect(resolved.description, 'General fund');
      // An exact decimal string, never a double; the send path parses it with
      // decimalToBaseUnits.
      expect(resolved.requestedAmount, isA<String>());
      expect(resolved.requestedAmount, '1.5');
      expect(resolved.memo, 'thanks');
    });
  });

  // The record layer has its own `hostile records` group in
  // `wallet_openalias/test/openalias_records_test.dart`; parsing never
  // throws, 2000-record sets resolve in order, a publisher cannot flood the
  // error message. Those stop where the plugin's job stops: it does not know
  // what a valid address looks like, and the wallet validates before anything
  // downstream sees it.
  //
  // This group covers that second half. Everything below is a field
  // the recipient's DNS controls, arriving in a record that already parsed
  // cleanly.
  group('hostile records the resolver accepted', () {
    test('every alternative is validated, not just the first', () async {
      await torOnPort('9050');
      installResolver(
        result: const ResolvedAlias(
          address: address,
          alternatives: [
            ResolvedAlias(address: 'bc1qwrongchain'),
            ResolvedAlias(address: address),
          ],
        ),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      final resolved = await wallet.resolveAlias('donate.example.org');

      // The alias published two payable-looking records and the app offers
      // both. Checking only the primary leaves the second one an unchecked
      // address a single tap from the send screen.
      expect(resolved!.alternatives.map((a) => a.address), [address]);
      expect(await logged(), contains('dropped 1 unusable alternative'));
    });

    test('a bad alternative does not sink a good primary', () async {
      await torOnPort('9050');
      installResolver(
        result: const ResolvedAlias(
          address: address,
          alternatives: [ResolvedAlias(address: 'garbage')],
        ),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      final resolved = await wallet.resolveAlias('donate.example.org');

      // Dropping the alternative is the right degradation: the record the
      // alias actually prioritised is still payable.
      expect(resolved!.address, address);
      expect(resolved.alternatives, isEmpty);
    });

    test('a record set far larger than a DNS answer is capped', () async {
      await torOnPort('9050');
      installResolver(
        result: ResolvedAlias(
          address: address,
          alternatives: List.generate(2000, (_) => const ResolvedAlias(address: address)),
        ),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      final resolved = await wallet.resolveAlias('donate.example.org');

      // All 2000 are individually payable, so validation alone would keep the
      // lot. This feeds a picker the user scrolls, not a batch job.
      expect(resolved!.alternatives, hasLength(AliasLimits.maxAlternatives));
    });

    test('an oversized address is refused rather than truncated', () async {
      await torOnPort('9050');
      installResolver(result: ResolvedAlias(address: 'A' * 60000));
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      // The plugin returns this verbatim by design, and says so.
      expect(await wallet.resolveAlias('donate.example.org'), isNull);
    });

    test('a junk requested amount survives resolution — parsing it is the send path job', () async {
      await torOnPort('9050');
      installResolver(
        result: const ResolvedAlias(address: address, requestedAmount: '1.2.3'),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      // `requestedAmount` is publisher-controlled text. Resolution must not
      // throw on it; `decimalToBaseUnits` is where it is rejected, and
      // `amounts_test.dart` pins that it handles "1.2.3", "." and "".
      final resolved = await wallet.resolveAlias('donate.example.org');
      expect(resolved!.requestedAmount, '1.2.3');
    });
  });

  group('display fields the publisher controls', () {
    /// Resolves a record carrying [name] as its recipient name.
    Future<ResolvedAlias?> withName(String name) async {
      await torOnPort('9050');
      installResolver(
        result: ResolvedAlias(address: address, recipientName: name),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);
      return wallet.resolveAlias('donate.example.org');
    }

    test('a right-to-left override is dropped, not displayed', () async {
      // U+202E reverses what follows. On a confirmation screen this is how a
      // name renders as something other than the characters it contains, which
      // is the whole trick behind a lookalike record.
      final resolved = await withName('Alice\u202Eevil');

      expect(resolved!.recipientName, isNull);
      // The payment itself is untouched; the address validated.
      expect(resolved.address, address);
    });

    test('a bidi isolate is dropped too', () async {
      expect((await withName('Shop\u2066 not really\u2069'))!.recipientName, isNull);
    });

    test('newlines are dropped — a name is one line', () async {
      // Otherwise a "name" can add its own rows to a confirmation dialog.
      expect((await withName('Alice\nTotal: 0.001 XMR'))!.recipientName, isNull);
    });

    test('zero-width characters are dropped', () async {
      expect((await withName('Ali\u200Bce'))!.recipientName, isNull);
    });

    test('an oversized name is dropped rather than truncated', () async {
      // Truncating leaves a name the publisher shaped, cut at a point they can
      // choose. Dropping shows nothing, which is honest.
      expect((await withName('A' * 5000))!.recipientName, isNull);
    });

    test('an ordinary name, including non-Latin script, is kept', () async {
      expect((await withName('Пример Фонд'))!.recipientName, 'Пример Фонд');
      expect((await withName('Example Charity'))!.recipientName, 'Example Charity');
    });

    test('description, memo and amount are held to the same rule', () async {
      await torOnPort('9050');
      installResolver(
        result: ResolvedAlias(
          address: address,
          description: 'Fine',
          memo: 'bad\u202Dmemo',
          // Parsing a megabyte of digits into a BigInt is superlinear; this is
          // a hang, not a value.
          requestedAmount: '9' * 100000,
        ),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      final resolved = await wallet.resolveAlias('donate.example.org');

      expect(resolved!.description, 'Fine');
      expect(resolved.memo, isNull);
      expect(resolved.requestedAmount, isNull);
    });

    test('an address carrying an invisible character never reaches the validator', () async {
      await torOnPort('9050');
      installResolver(result: ResolvedAlias(address: '$address\u200B'));
      // A coin whose validator accepts anything; the bounds check is what
      // stands between a hostile record and the send screen here.
      final permissive = FakeAliasWallet('XMR', network: 'xmr');
      addTearDown(permissive.dispose);

      expect(await permissive.resolveAlias('donate.example.org'), isNull);
    });

    test('an alternative sanitizes its own fields', () async {
      await torOnPort('9050');
      installResolver(
        result: ResolvedAlias(
          address: address,
          alternatives: [ResolvedAlias(address: address, recipientName: 'x\u202Ey')],
        ),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      final resolved = await wallet.resolveAlias('donate.example.org');

      // The alternatives are shown in the same picker as the primary, so they
      // get the same treatment rather than a lighter one.
      expect(resolved!.alternatives.single.recipientName, isNull);
    });

    test('alternatives are flattened — nesting cannot smuggle a record through', () async {
      await torOnPort('9050');
      installResolver(
        result: const ResolvedAlias(
          address: address,
          alternatives: [
            ResolvedAlias(
              address: address,
              alternatives: [ResolvedAlias(address: 'unchecked')],
            ),
          ],
        ),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      final resolved = await wallet.resolveAlias('donate.example.org');

      // The type is recursive but the resolver's shape is flat. A nested list
      // would otherwise be a second tier nothing validates.
      expect(resolved!.alternatives.single.alternatives, isEmpty);
    });
  });

  group('logging', () {
    test('the alias is fingerprinted, never named', () async {
      await torOnPort('9050');
      installResolver(result: const ResolvedAlias(address: address));
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      await wallet.resolveAlias('donate.example.org');
      final out = await logged();

      // The alias is who the user is paying. A log naming it is a record of
      // their counterparties sitting in the app's own files.
      expect(out, isNot(contains('donate.example.org')));
      expect(out, isNot(contains('example.org')));
      expect(out, contains('alias:'), reason: 'still followable by fingerprint');
    });

    test('the resolved address is not logged either', () async {
      await torOnPort('9050');
      installResolver(
        result: const ResolvedAlias(address: address, recipientName: 'Someone'),
      );
      final wallet = FakeAliasWallet('XMR', network: 'xmr')..validAddresses = {address};
      addTearDown(wallet.dispose);

      await wallet.resolveAlias('donate.example.org');
      final out = await logged();

      expect(out, isNot(contains(address)));
      expect(out, isNot(contains('Someone')));
    });
  });
}
