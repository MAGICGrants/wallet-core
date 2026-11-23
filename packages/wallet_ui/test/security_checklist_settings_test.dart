import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart' show SeedCheckStore;
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_ui/wallet_ui.dart';

final _now = DateTime.utc(2026, 10, 19, 12);

String _progress(int done, int total) => '$done of $total';

const _steps = SecurityChecklistLabels(
  title: 'Secure Your Wallet',
  progress: _progress,
  verifySeed: 'Verify',
  autoBackup: 'Backup',
  tor: 'Tor',
  privateLookups: 'Lookups',
  securityKeys: 'Key',
);

const _labels = SecurityChecklistSheetLabels(
  title: 'Security Checklist',
  subtitle: 'Choose what the home shows.',
  homeSection: 'Home Screen',
  showOnHome: 'Show on Home',
  showOnHomeDesc: 'Until every step is done',
  stepsSection: 'Remind Me About',
  done: 'Done',
  notDone: 'Not done',
  seedDone: 'Done, asked again',
  steps: _steps,
  save: 'Save',
  cancel: 'Cancel',
);

void main() {
  setUp(() {
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
  });

  tearDown(() {
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    TorSettingsService.sharedInstance.resetForTesting();
    debugIsDesktopModalOverride = null;
  });

  /// Automatic backup does not apply; the seed check is current, Tor and the
  /// lookups are as they start; a security key is set up when [keys] says so.
  SecurityChecklist checklistWith({required bool Function() keys}) {
    final checklist = SecurityChecklist(
      autoBackupOn: () async => null,
      securityKeysOn: () async => keys(),
      clock: () => _now,
    );
    addTearDown(checklist.dispose);
    return checklist;
  }

  group('SecurityChecklistSettings', () {
    test('shown with every step until saved otherwise, and a save reads back', () async {
      expect(await SecurityChecklistSettings.load(), const SecurityChecklistSettings());

      const chosen = SecurityChecklistSettings(
        showOnHome: false,
        stepsOff: {SecurityStep.securityKeys, SecurityStep.tor},
      );
      await chosen.save();
      expect(await SecurityChecklistSettings.load(), chosen);
    });

    test('a step name this version does not know is dropped', () async {
      await SharedPreferencesService.set<List<String>>(SettingsKeys.securityChecklistStepsOff, [
        'securityKeys',
        'retiredStep',
      ]);
      expect((await SecurityChecklistSettings.load()).stepsOff, {SecurityStep.securityKeys});
    });
  });

  group('SecurityChecklist with settings', () {
    test('a step switched off leaves the card, and its setting no longer brings it back', () async {
      var keys = false;
      final checklist = checklistWith(keys: () => keys);
      await SeedCheckStore.markVerified(_now);
      await checklist.refresh();
      expect(checklist.shownOnHome, isTrue, reason: 'no security key yet');

      await const SecurityChecklistSettings(stepsOff: {SecurityStep.securityKeys}).save();
      await checklist.refresh();
      expect(checklist.steps![SecurityStep.securityKeys], isFalse, reason: 'still read');
      expect(checklist.homeSteps!.containsKey(SecurityStep.securityKeys), isFalse);
      expect(checklist.allDone, isTrue);
      expect(
        securityChecklistCard(checklist: checklist, labels: _steps, onStep: (_) async {}),
        isNull,
      );

      // The reporter's case: a key set up, then removed.
      keys = true;
      await checklist.refresh();
      keys = false;
      await checklist.refresh();
      expect(checklist.shownOnHome, isFalse);
    });

    test('Show on Home off hides the card whatever is left to do', () async {
      final checklist = checklistWith(keys: () => false);
      await const SecurityChecklistSettings(showOnHome: false).save();
      await checklist.refresh();

      expect(checklist.allDone, isFalse);
      expect(checklist.shownOnHome, isFalse);
      expect(
        securityChecklistCard(checklist: checklist, labels: _steps, onStep: (_) async {}),
        isNull,
      );
    });

    test('a save updates a checklist already on screen', () async {
      final checklist = checklistWith(keys: () => false);
      await checklist.refresh();
      expect(checklist.shownOnHome, isTrue);

      final changed = Completer<void>();
      checklist.addListener(() {
        if (!changed.isCompleted) changed.complete();
      });
      await const SecurityChecklistSettings(showOnHome: false).save();
      await changed.future;
      expect(checklist.shownOnHome, isFalse);
    });
  });

  group('the Security Checklist card', () {
    /// What the card resolved to, once it closed.
    bool? result;

    Future<void> open(WidgetTester tester, SecurityChecklist checklist) async {
      debugIsDesktopModalOverride = false;
      result = null;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showSecurityChecklistSheet(
                  context,
                  checklist: checklist,
                  labels: _labels,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> tapRow(WidgetTester tester, String title) async {
      await tester.ensureVisible(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pump();
    }

    bool switchOf(WidgetTester tester, String title) => tester
        .widget<SettingsToggleTile>(
          find.ancestor(of: find.text(title), matching: find.byType(SettingsToggleTile)),
        )
        .value;

    testWidgets('lists the steps that apply and where each stands; Save stores the switches', (
      tester,
    ) async {
      await SeedCheckStore.markVerified(_now);
      await open(tester, checklistWith(keys: () => false));

      expect(find.text('Show on Home'), findsOneWidget);
      expect(find.text('Backup'), findsNothing, reason: 'automatic backup does not apply here');
      expect(find.text('Done, asked again'), findsOneWidget);
      expect(find.text('Not done'), findsOneWidget);
      expect(switchOf(tester, 'Key'), isTrue);

      await tapRow(tester, 'Key');
      expect(switchOf(tester, 'Key'), isFalse);
      expect(
        await SecurityChecklistSettings.load(),
        const SecurityChecklistSettings(),
        reason: 'nothing applies before Save',
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(
        await SecurityChecklistSettings.load(),
        const SecurityChecklistSettings(stepsOff: {SecurityStep.securityKeys}),
      );
    });

    testWidgets('opens on what was saved, and Cancel leaves it alone', (tester) async {
      const saved = SecurityChecklistSettings(showOnHome: false, stepsOff: {SecurityStep.tor});
      await saved.save();
      await open(tester, checklistWith(keys: () => false));

      expect(switchOf(tester, 'Show on Home'), isFalse);
      expect(switchOf(tester, 'Tor'), isFalse);
      expect(switchOf(tester, 'Key'), isTrue);

      await tapRow(tester, 'Show on Home');
      expect(switchOf(tester, 'Show on Home'), isTrue);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(await SecurityChecklistSettings.load(), saved);
    });
  });
}
