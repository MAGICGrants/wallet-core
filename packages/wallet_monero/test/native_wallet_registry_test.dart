import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// Android destroys the app's isolate when the user swipes the app away, and
/// nothing in it closes its native wallets, while Continuous Sync keeps the
/// process alive. The app lists its open native wallets by process and isolate,
/// so whoever takes over closes those left behind, and nobody else's.
void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  const thisProcess = 4242;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('native_wallets');
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    useTestCaBundle();
    WalletLog.sink = MemoryLogSink();
    NativeWalletRegistry.enabled = true;
    NativeWalletRegistry.processId = () => thisProcess;
    NativeWalletRegistry.resetForTesting();
    backend = FakeMoneroBackend();
  });

  tearDown(() {
    NativeWalletRegistry.enabled = Platform.isAndroid;
    NativeWalletRegistry.processId = () => pid;
    WalletAppConfig.resetForTesting();
    CaBundle.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File listFile() => File('${tmp.path}/${NativeWalletRegistry.fileName}');

  List<Map<String, dynamic>> listed() => [
    for (final w in (jsonDecode(listFile().readAsStringSync())['wallets'] as List))
      Map<String, dynamic>.from(w as Map),
  ];

  void writeList(int process, List<Map<String, Object>> wallets) =>
      listFile().writeAsStringSync(jsonEncode({'pid': process, 'wallets': wallets}));

  test(
    'a destroyed isolate\'s wallets are closed; this one\'s and a live one\'s are not',
    () async {
      await NativeWalletRegistry.add(const NativeHandle(1), const NativeHandle(10));
      writeList(thisProcess, [
        ...listed().map((w) => w.cast<String, Object>()),
        {'token': 'destroyed', 'manager': 1, 'wallet': 20},
        {'token': 'live', 'manager': 1, 'wallet': 30},
      ]);

      await closeOrphanedMoneroWallets(exceptToken: 'live', backend: backend);
      expect(backend.closedWallets, [20]);
      expect(listed().map((w) => w['wallet']), unorderedEquals([10, 30]));
    },
  );

  test('a list another process left is never acted on: its handles mean nothing here', () async {
    writeList(1111, [
      {'token': 'destroyed', 'manager': 1, 'wallet': 20},
    ]);
    await closeOrphanedMoneroWallets(backend: backend);
    expect(backend.closedWallets, isEmpty);
  });

  test('an unreadable list is treated as empty', () async {
    listFile().writeAsStringSync('not json');
    await closeOrphanedMoneroWallets(backend: backend);
    expect(backend.closedWallets, isEmpty);
  });

  test('the app\'s wallet is listed while open, and comes off before it closes', () async {
    final wallet = MoneroWallet(backend: backend);
    addTearDown(wallet.dispose);
    wallet.setConnection(
      address: 'node.example.com:18081',
      proxyPort: '',
      useTor: false,
      connectionType: 'node',
    );
    backend.existingWalletPaths.add(await wallet.walletPathForType('node'));
    await wallet.openExisting(password: 'pw');

    expect(listed(), [
      {'token': WalletIsolate.token, 'manager': isA<int>(), 'wallet': isA<int>()},
    ]);
    // Its own isolate's: never closed as an orphan.
    await closeOrphanedMoneroWallets(backend: backend);
    expect(backend.closedWallets, isEmpty);

    await wallet.close();
    expect(listed(), isEmpty);
    expect(backend.closedWallets, hasLength(1));
  });

  test('off Android nothing is written', () async {
    NativeWalletRegistry.enabled = false;
    await NativeWalletRegistry.add(const NativeHandle(1), const NativeHandle(10));
    expect(listFile().existsSync(), isFalse);
  });
}
