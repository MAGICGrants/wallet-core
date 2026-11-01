import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

ConnectionFormView _form({String? warning, VoidCallback? onCancel}) => ConnectionFormView(
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
  errorMessage: null,
  warning: warning,
  proxyController: TextEditingController(),
  onProxyChanged: (_) {},
  proxyEnabled: true,
  connectionTypeLabels: const [],
  selectedTypeIndex: 0,
  onSelectType: (_) {},
  useTor: false,
  torDisabled: true,
  onToggleTor: () {},
  pillProxyPort: '',
  pillAddress: '',
  testState: ConnectionTestState.idle,
  onTest: () {},
  onStopTest: () {},
  onTestAgain: () {},
  successDetail: '',
  saveButtonLabel: 'Save',
  canSave: false,
  onSave: () {},
  cancelLabel: onCancel == null ? null : 'Cancel',
  onCancel: onCancel,
);

void main() {
  testWidgets('renders the warning callout when warning is set', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _form(warning: 'Tor was disabled for this connection')),
      ),
    );
    expect(find.text('Tor was disabled for this connection'), findsOneWidget);
    expect(find.byIcon(Icons.warning_rounded), findsOneWidget);
  });

  testWidgets('omits the warning callout when warning is null', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: _form(warning: null))));
    expect(find.byIcon(Icons.warning_rounded), findsNothing);
  });

  // A settings sheet passes Cancel and gets Save + Cancel like the other settings
  // sheets; onboarding passes none and keeps Save alone.
  testWidgets('a settings sheet gets Cancel beside Save', (tester) async {
    var cancelled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: _form(onCancel: () => cancelled++)),
        ),
      ),
    );
    expect(find.byType(SheetActions), findsOneWidget);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    expect(cancelled, 1);
  });

  testWidgets('without onCancel, Save stands alone', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: _form())),
      ),
    );
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.byType(SheetActions), findsNothing);
  });
}
