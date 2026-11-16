import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// Every control the shared screens draw has a name a screen reader can say
/// (Flutter's labeledTapTargetGuideline): an icon-only button, a covered
/// secret's reveal, a field named only by its placeholder. A control that
/// reads as just "button" fails here.
///
/// Not checked: tap-target size and text contrast. The brand's own sizes and
/// colours set those, and changing them changes how the apps look.
void main() {
  Widget app(Widget home) => MaterialApp(
    localizationsDelegates: WalletUiLocalizations.localizationsDelegates,
    supportedLocales: WalletUiLocalizations.supportedLocales,
    home: home,
  );

  Future<void> expectEveryControlNamed(WidgetTester tester) =>
      expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  for (final desktop in [false, true]) {
    testWidgets('unlock (${desktop ? 'desktop' : 'phone'})', (tester) async {
      final handle = tester.ensureSemantics();
      phone(tester);
      await tester.pumpWidget(
        app(
          UnlockView(
            logo: const SizedBox.shrink(),
            labels: const UnlockLabels(
              title: 'Locked',
              passwordHint: 'Password',
              unlockButton: 'Unlock',
            ),
            isDesktop: desktop,
            passwordController: TextEditingController(),
            obscure: true,
            onToggleObscure: () {},
            onUnlockPassword: () {},
            onUnlockBiometric: () {},
            error: 'Wrong password',
            recoveryLabel: 'Use recovery phrase',
            onUseRecoveryPhrase: () {},
          ),
        ),
      );
      await tester.pump();
      await expectEveryControlNamed(tester);
      handle.dispose();
    });
  }

  testWidgets('receive', (tester) async {
    final handle = tester.ensureSemantics();
    phone(tester);
    await tester.pumpWidget(
      app(
        ReceiveView(
          labels: const ReceiveLabels(
            title: 'Receive',
            copyAddress: 'Copy address',
            enlargeQr: 'Tap to enlarge and brighten',
            shrinkQr: 'Tap to shrink',
          ),
          onBack: () {},
          onShare: (_) {},
          ready: true,
          coinSymbol: 'XMR',
          iconAsset: 'assets/icons/monero.svg',
          coinName: null,
          blockchainSubtitle: null,
          address: '4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge',
          qrHeading: 'Subaddress #1',
          onCopy: () {},
        ),
      ),
    );
    await tester.pump();
    await expectEveryControlNamed(tester);
    handle.dispose();
  });

  testWidgets('connection form', (tester) async {
    final handle = tester.ensureSemantics();
    phone(tester);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: SingleChildScrollView(
            child: ConnectionFormView(
              labels: const ConnectionFormLabels(
                proxyPortLabel: 'Proxy port',
                proxyPortHint: 'port',
                useTorLabel: 'Use Tor',
                startingTorTitle: 'Starting Tor',
                testButton: 'Test',
                testStop: 'Stop',
                testingTitle: 'Testing',
                testingDetail: 'detail',
                testAgain: 'Test again',
                resultWorksTitle: 'Works',
                resultFailedTitle: 'Failed',
                resultFailedDetail: 'failed detail',
              ),
              addressLabel: 'Address',
              addressHint: 'hint',
              addressController: TextEditingController(),
              onAddressChanged: (_) {},
              errorMessage: 'Not a valid address',
              proxyController: TextEditingController(),
              onProxyChanged: (_) {},
              proxyEnabled: true,
              connectionTypeLabels: const ['LWS', 'Node'],
              selectedTypeIndex: 0,
              onSelectType: (_) {},
              useTor: true,
              torDisabled: false,
              onToggleTor: () {},
              pillProxyPort: '',
              pillAddress: '',
              testState: ConnectionTestState.idle,
              onTest: () {},
              onStopTest: () {},
              onTestAgain: () {},
              successDetail: '',
              saveButtonLabel: 'Save',
              canSave: true,
              onSave: () {},
              onScan: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await expectEveryControlNamed(tester);
    handle.dispose();
  });

  testWidgets('secret keys, covered', (tester) async {
    final handle = tester.ensureSemantics();
    phone(tester);
    await tester.pumpWidget(
      app(
        KeyRevealView(
          title: 'Secret Keys',
          revealLabel: 'Tap to reveal',
          onCopy: (_) {},
          onBack: () {},
          fields: const [
            KeyRevealField(label: 'Primary Address', value: '4Ad…Rge'),
            KeyRevealField(label: 'Secret View Key', value: '0f1e2d', revealable: true),
          ],
        ),
      ),
    );
    await expectEveryControlNamed(tester);
    handle.dispose();
  });

  testWidgets('desktop seed step, covered and revealed', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        DesktopGenerateSeedView(
          logo: const SizedBox(height: 52),
          title: 'Your seed',
          description: 'Write these words down, in order.',
          seedWords: const ['abandon', 'ability', 'able', 'about'],
          birthdayLabel: 'Wallet birthday',
          birthdayReason: 'Where a restore starts scanning',
          birthdayValue: 'October 2026',
          confirmLabel: 'I wrote it down',
          passwordNote: null,
          revealLabel: 'Tap to reveal',
          continueText: 'Next',
          step: 4,
          totalSteps: 5,
          onContinue: () {},
          onBack: () {},
        ),
      ),
    );
    await expectEveryControlNamed(tester);
    await tester.tap(find.text('Tap to reveal'));
    await tester.pumpAndSettle();
    await expectEveryControlNamed(tester);
    handle.dispose();
  });

  testWidgets('shared controls', (tester) async {
    final handle = tester.ensureSemantics();
    phone(tester);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ListView(
            children: [
              BrandScreenHeader(
                onBack: () {},
                center: const Text('Settings'),
                action: IconCircleButton(icon: Icons.tune, onPressed: () {}, semanticLabel: 'More'),
              ),
              SettingsGroup(
                label: 'General',
                tiles: [
                  SettingsNavTile(title: 'Theme', value: 'System', onTap: () {}),
                  SettingsLinkTile(title: 'Logs', linkLabel: 'Export', onTap: () {}),
                  SettingsToggleTile(title: 'Notifications', value: true, onChanged: (_) {}),
                ],
              ),
              BrandSegmented(labels: const ['Low', 'Normal'], selectedIndex: 0, onSelect: (_) {}),
              ModeSelectCard(
                title: 'Built-in Tor',
                description: 'Recommended',
                selected: true,
                onTap: () {},
              ),
              OptionCard(
                icon: Icons.cloud_outlined,
                title: 'iCloud',
                description: 'Back up payment notes',
                trailing: BrandSwitch(value: false, onChanged: (_) {}),
              ),
              FiatCurrencyChip(code: 'USD', symbol: r'$', selected: true, onTap: () {}),
              MiniActionButton(icon: Icons.content_paste, label: 'Paste', onTap: () {}),
              ActionButton(icon: Icons.arrow_downward, label: 'Receive', onPressed: () {}),
              BrandButton(label: 'Continue', onPressed: () {}, loading: true),
              SeedGrid(
                words: const ['abandon', 'ability'],
                revealed: false,
                revealLabel: 'Tap to reveal',
                onReveal: () {},
              ),
              BrandTextField(caption: 'Wallet Name', controller: TextEditingController()),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await expectEveryControlNamed(tester);
    handle.dispose();
  });
}
