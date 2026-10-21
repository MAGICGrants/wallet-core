import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_ui/wallet_ui.dart';

const _labels = SyncFrequencyLabels(
  title: 'Sync Frequency',
  subtitle: 'How often your wallets sync while the app is closed.',
  modeLabel: 'Frequency',
  continuous: 'Continuous',
  continuousDesc: 'Always up to date',
  periodic: 'Periodic',
  periodicDesc: 'Usually up to date',
  off: 'Off',
  offDesc: 'Only while open',
  save: 'Save',
  cancel: 'Cancel',
);

void main() {
  setUp(() => SharedPreferencesService.store = MemoryPreferenceStore());
  tearDown(() {
    SharedPreferencesService.resetForTesting();
    syncFrequencyPlatform = Platform.operatingSystem;
    debugIsDesktopModalOverride = null;
  });

  /// What the sheet resolved to, once it closed.
  SyncFrequency? result;

  Future<void> open(WidgetTester tester) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showSyncFrequencySheet(context, labels: _labels),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Android offers all three; saving resolves to the one picked', (tester) async {
    debugIsDesktopModalOverride = false;
    syncFrequencyPlatform = 'android';
    await open(tester);

    expect(find.text('Continuous'), findsOneWidget);
    expect(find.text('Periodic'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);

    await tester.tap(find.text('Continuous'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, SyncFrequency.continuous);
    // Saving the choice is the app's job, with the services it starts.
    expect(await SharedPreferencesService.get<String>(SettingsKeys.syncFrequency), isNull);
  });

  testWidgets('iOS has no Continuous', (tester) async {
    debugIsDesktopModalOverride = false;
    syncFrequencyPlatform = 'ios';
    await open(tester);

    expect(find.text('Continuous'), findsNothing);
    expect(find.text('Periodic'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('cancel resolves to nothing', (tester) async {
    debugIsDesktopModalOverride = false;
    syncFrequencyPlatform = 'android';
    await open(tester);

    await tester.tap(find.text('Off'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
