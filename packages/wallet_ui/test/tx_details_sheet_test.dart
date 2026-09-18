import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// The sheet is localization-agnostic: it renders and copies using only the
/// injected [TxDetailsSheetLabels], with no app l10n in scope. A fake wallet
/// (not a real coin) supplies the display getters — a real [CryptoWallet] would
/// leave background timers pending past the test.
class _FakeWallet implements CryptoWallet {
  @override
  String get coinSymbol => 'XMR';
  @override
  String get feeCoinSymbol => 'XMR';
  @override
  String get iconAsset => '';
  @override
  int get baseUnitDecimals => 12;
  @override
  int get feeBaseUnitDecimals => 12;
  @override
  int get decimals => 4;
  @override
  int get feeDecimals => 4;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _labels = TxDetailsSheetLabels(
  title: 'Transaction',
  hash: 'Hash',
  amount: 'Amount',
  networkFee: 'Network fee',
  timeAndDate: 'Date',
  confirmationHeight: 'Height',
  confirmations: 'Confirmations',
  viewKey: 'View key',
  recipients: 'Recipients',
  changeRecipient: 'Change',
  close: 'Close',
  copied: 'Copied!',
  received: 'Received',
  sent: 'Sent',
  copyHint: 'tap any value to copy',
);

void main() {
  TxDetails sampleTx({TxStatus status = TxStatus.ok}) => TxDetails(
    index: 0,
    direction: 0,
    hash: 'deadbeefcafe0123456789',
    amountBaseUnits: BigInt.from(1500000000000), // 1.5 XMR
    feeBaseUnits: BigInt.zero,
    recipients: const [],
    accountIndex: 0,
    subaddrIndexList: const [],
    timestamp: 1600000000,
    height: 100,
    confirmations: 5,
    key: '',
    status: status,
  );

  /// Opens the sheet over [tx] and settles.
  Future<void> open(WidgetTester tester, TxDetails tx, [TxDetailsSheetLabels? labels]) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showTxDetailsSheet(
                  context: context,
                  wallet: _FakeWallet(),
                  tx: tx,
                  labels: labels ?? _labels,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders injected labels; tapping a value copies it with feedback', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': copied};
      return null;
    });

    await open(tester, sampleTx());

    // Injected labels are shown (no app l10n present).
    expect(find.text('Transaction'), findsOneWidget);
    expect(find.text('Amount'), findsOneWidget);

    await tester.tap(find.text('1.5000 XMR'));
    await tester.pump(); // surface the snackbar

    expect(copied, '1.5000 XMR');
    expect(find.text('Copied!'), findsOneWidget);

    // Drain SecureClipboard's 60s auto-clear timer so no timer outlives the test.
    await tester.pump(const Duration(seconds: 61));
  });

  group('recipient lines', () {
    const addrA = '4AdUndZHHKJpkDoDsoLKnMRdbA4vBQ8kHhjPRkTTNgiMHiqBUbnSWkFa8rMbWFkNCK6QKLhF8Fh';
    const addrB = '86bNCYdW1qTjq8Y1kFDVJgtnBQJiqmbEkiiPRwWLxmkFwPuYBqnsRVdBhB4E1QKh7FkVGaBhkGz';

    TxDetails withRecipients(List<TxRecipient> recipients) => TxDetails(
      index: 0,
      direction: 1,
      hash: 'deadbeefcafe0123456789',
      amountBaseUnits: BigInt.from(1500000000000),
      feeBaseUnits: BigInt.zero,
      recipients: recipients,
      accountIndex: 0,
      subaddrIndexList: const [],
      timestamp: 1600000000,
      height: 100,
      confirmations: 5,
      key: '',
    );

    /// Captures whatever reaches the platform clipboard.
    String? Function() mockClipboard(WidgetTester tester) {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
        call,
      ) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': copied};
        return null;
      });
      return () => copied;
    }

    testWidgets('every address and every amount has its own copy icon', (tester) async {
      await open(
        tester,
        withRecipients([
          TxRecipient(addrA, BigInt.from(1000000000000)),
          TxRecipient(addrB, BigInt.from(500000000000)),
        ]),
      );

      // Two recipients, so four on this line pair, plus one per single-value row.
      final icons = find.descendant(
        of: find.byType(Row),
        matching: find.byIcon(Icons.copy_outlined),
      );
      expect(icons, findsAtLeast(4));
      expect(find.text('1.0000 XMR'), findsOneWidget);
      expect(find.text('0.5000 XMR'), findsOneWidget);
    });

    /// The two copy icons on the recipient line for [shortAddress], in order:
    /// the one after the address, then the one after the amount.
    Finder lineIcons(String shortAddress) {
      final text = find.text(shortAddress);
      expect(text, findsOneWidget, reason: 'anchor the line on its address');
      final line = find.ancestor(of: text, matching: find.byType(Row)).first;
      return find.descendant(of: line, matching: find.byIcon(Icons.copy_outlined));
    }

    /// The sheet scrolls, and the recipient list sits below the fold.
    Future<void> tapIcon(WidgetTester tester, Finder icon) async {
      await tester.ensureVisible(icon);
      await tester.pumpAndSettle();
      await tester.tap(icon);
      await tester.pump();
    }

    testWidgets('the icon beside an address copies it in full, never shortened', (tester) async {
      final copied = mockClipboard(tester);
      await open(tester, withRecipients([TxRecipient(addrA, BigInt.from(1000000000000))]));

      await tapIcon(tester, lineIcons('4AdUnd…F8Fh').at(0));

      expect(copied(), addrA);
      expect(copied(), isNot(contains('…')), reason: 'never the shortened display text');
      expect(copied(), isNot(contains('-')), reason: 'an address is copied verbatim');
      await tester.pump(const Duration(seconds: 61));
    });

    testWidgets('the icon beside an amount copies the amount, not the address', (tester) async {
      final copied = mockClipboard(tester);
      await open(tester, withRecipients([TxRecipient(addrA, BigInt.from(1000000000000))]));

      await tapIcon(tester, lineIcons('4AdUnd…F8Fh').at(1));

      // The same text the amount row above the list copies.
      expect(copied(), '1.0000 XMR');
      await tester.pump(const Duration(seconds: 61));
    });

    testWidgets('a second recipient gets its own pair, bound to its own values', (tester) async {
      final copied = mockClipboard(tester);
      await open(
        tester,
        withRecipients([
          TxRecipient(addrA, BigInt.from(1000000000000)),
          TxRecipient(addrB, BigInt.from(500000000000)),
        ]),
      );

      await tapIcon(tester, lineIcons('86bNCY…hkGz').at(0));
      expect(copied(), addrB);

      await tapIcon(tester, lineIcons('86bNCY…hkGz').at(1));
      expect(copied(), '0.5000 XMR');
      await tester.pump(const Duration(seconds: 61));
    });
  });

  group('change is shown like any other recipient', () {
    const ourAddr = '4AdUndZHHKJpkDoDsoLKnMRdbA4vBQ8kHhjPRkTTNgiMHiqBUbnSWkFa8rMbWFkNCK6QKLhF8Fh';
    const changeAddr =
        '86bNCYdW1qTjq8Y1kFDVJgtnBQJiqmbEkiiPRwWLxmkFwPuYBqnsRVdBhB4E1QKh7FkVGaBhkGz';

    TxDetails sent() => TxDetails(
      index: 0,
      direction: 1,
      hash: 'deadbeefcafe0123456789',
      amountBaseUnits: BigInt.from(1500000000000),
      feeBaseUnits: BigInt.zero,
      recipients: [
        TxRecipient(ourAddr, BigInt.from(1000000000000)),
        TxRecipient(changeAddr, BigInt.from(500000000000), isChange: true),
      ],
      accountIndex: 0,
      subaddrIndexList: const [],
      timestamp: 1600000000,
      height: 100,
      confirmations: 5,
      key: '',
    );

    testWidgets('it carries its amount, not just its address', (tester) async {
      await open(tester, sent());

      expect(find.text('Change'), findsOneWidget);
      // The address-only row showed no amount at all for change.
      expect(find.text('0.5000 XMR'), findsOneWidget);
    });

    testWidgets('its address and amount each copy their own value', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
        call,
      ) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': copied};
        return null;
      });

      await open(tester, sent());

      final line = find.ancestor(of: find.text('86bNCY…hkGz'), matching: find.byType(Row)).first;
      final icons = find.descendant(of: line, matching: find.byIcon(Icons.copy_outlined));

      await tester.ensureVisible(icons.at(0));
      await tester.pumpAndSettle();
      await tester.tap(icons.at(0));
      await tester.pump();
      expect(copied, changeAddr, reason: 'the full change address, unshortened');

      await tester.tap(icons.at(1));
      await tester.pump();
      expect(copied, '0.5000 XMR');

      await tester.pump(const Duration(seconds: 61));
    });
  });

  group('the status banner', () {
    testWidgets('a successful transaction shows none', (tester) async {
      await open(tester, sampleTx());
      // Everything on this sheet reads as a receipt, which is correct here and
      // was the bug when the transaction had failed.
      expect(find.textContaining('failed'), findsNothing);
      expect(find.textContaining('not confirmed'), findsNothing);
    });

    testWidgets('a failed transaction says so, above everything else', (tester) async {
      await open(tester, sampleTx(status: TxStatus.failed));
      expect(find.text('This transaction failed. The funds were not sent.'), findsOneWidget);
    });

    testWidgets('an unresolved broadcast says that instead', (tester) async {
      await open(tester, sampleTx(status: TxStatus.unknown));
      expect(
        find.text('This transaction was not confirmed as sent. Check before sending again.'),
        findsOneWidget,
      );
    });

    testWidgets('an app-supplied string wins over the fallback', (tester) async {
      // The fallback exists so the status is never silently dropped; a localized
      // string must still take precedence once an app provides one.
      await open(
        tester,
        sampleTx(status: TxStatus.failed),
        const TxDetailsSheetLabels(
          title: 'Transaction',
          hash: 'Hash',
          amount: 'Amount',
          networkFee: 'Network fee',
          timeAndDate: 'Date',
          confirmationHeight: 'Height',
          confirmations: 'Confirmations',
          viewKey: 'View key',
          recipients: 'Recipients',
          changeRecipient: 'Change',
          close: 'Close',
          copied: 'Copied!',
          received: 'Received',
          sent: 'Sent',
          copyHint: 'tap any value to copy',
          failed: 'Transaktion fehlgeschlagen',
        ),
      );
      expect(find.text('Transaktion fehlgeschlagen'), findsOneWidget);
      expect(find.textContaining('The funds were not sent'), findsNothing);
    });
  });
}
