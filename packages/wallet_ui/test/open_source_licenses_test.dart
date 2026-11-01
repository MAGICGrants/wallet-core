import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// The license list groups LicenseRegistry by package, and a package's page
/// shows each of its licenses.
void main() {
  setUp(LicenseRegistry.reset);
  tearDown(LicenseRegistry.reset);

  void add(List<String> packages, String text) =>
      LicenseRegistry.addLicense(() => Stream.value(LicenseEntryWithLineBreaks(packages, text)));

  test('groups entries by package, sorted by name whatever the case', () async {
    add(['zeta'], 'Zeta license');
    add(['Alpha', 'beta'], 'Shared license');
    add(['beta'], 'Beta license');

    final packages = await loadPackageLicenses();

    expect(packages.map((p) => p.package), ['Alpha', 'beta', 'zeta']);
    expect(packages[1].entries, hasLength(2), reason: 'a shared entry is listed under each');
  });

  testWidgets('a package shows every license, one divider between two', (tester) async {
    add(['pkg'], 'First license');
    add(['pkg'], 'Second license');
    final pkg = (await tester.runAsync(loadPackageLicenses))!.single;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LicenseTextView(package: pkg)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('First license'), findsOneWidget);
    expect(find.text('Second license'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
