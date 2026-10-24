import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart' show OpenAliasMode;
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_ui/wallet_ui.dart';

const _labels = OpenAliasSettingsLabels(
  title: 'OpenAlias Settings',
  subtitle: 'How names are looked up.',
  modeLabel: 'Mode',
  torOnly: 'Tor-Only',
  torOnlyDesc: 'Names looked up over Tor',
  clearnet: 'Clearnet-Only',
  clearnetDesc: 'Not private',
  disabled: 'Disabled',
  disabledDesc: 'No lookups',
  save: 'Save',
  cancel: 'Cancel',
);

void main() {
  setUp(() => SharedPreferencesService.store = MemoryPreferenceStore());
  tearDown(() {
    SharedPreferencesService.resetForTesting();
    TorSettingsService.sharedInstance.resetForTesting();
    debugIsDesktopModalOverride = null;
  });

  /// What the sheet resolved to, once it closed.
  bool? result;

  Future<void> open(WidgetTester tester) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showOpenAliasSettingsSheet(context, labels: _labels),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('three choices, Tor-only first; saving stores the one picked', (tester) async {
    debugIsDesktopModalOverride = false;
    await open(tester);

    expect(find.text('Tor-Only'), findsOneWidget);
    expect(find.text('Clearnet-Only'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);

    await tester.tap(find.text('Clearnet-Only'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(await OpenAliasMode.load(), OpenAliasMode.clearnet);
  });

  testWidgets('with Tor off, Tor-only is not offered', (tester) async {
    debugIsDesktopModalOverride = false;
    await TorSettingsService.sharedInstance.save(torMode: TorMode.disabled);
    await open(tester);

    expect(find.text('Tor-Only'), findsNothing);
    expect(find.text('Clearnet-Only'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);

    // Cancel leaves the saved choice alone.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await OpenAliasMode.load(), OpenAliasMode.torOnly);
  });
}
