import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// Entered from the multicoin home, Receive may open on a chain whose address
/// is not ready yet (no server set up, or still syncing). The asset picker must
/// stay on screen then, or there is no way to switch to a chain that works.
void main() {
  Widget view({required bool ready, List<ReceiveAssetOption> options = const []}) => MaterialApp(
    home: ReceiveView(
      labels: const ReceiveLabels(title: 'Receive', copyAddress: 'Copy address'),
      onBack: () {},
      ready: ready,
      coinSymbol: 'XMR',
      iconAsset: '',
      coinName: 'Monero',
      blockchainSubtitle: 'Monero blockchain',
      assetOptions: options,
      onSelectAsset: (_) {},
      address: '',
      qrHeading: '',
      onCopy: () {},
    ),
  );

  const options = <ReceiveAssetOption>[
    (coinSymbol: 'XMR', iconAsset: '', coinName: 'Monero'),
    (coinSymbol: 'BTC', iconAsset: '', coinName: 'Bitcoin'),
    (coinSymbol: 'ETH', iconAsset: '', coinName: 'Ethereum'),
  ];

  testWidgets('the picker stays while the address loads', (tester) async {
    await tester.pumpWidget(view(ready: false, options: options));
    expect(find.byType(ReceiveAssetSelectorCard), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Copy address'), findsNothing);
  });

  testWidgets('a single coin still shows its card while loading', (tester) async {
    await tester.pumpWidget(view(ready: false));
    expect(find.text('Monero'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
