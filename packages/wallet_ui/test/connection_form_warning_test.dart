import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

ConnectionFormView _form({String? warning}) => ConnectionFormView(
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
}
