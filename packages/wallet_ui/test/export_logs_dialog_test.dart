import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart' show LogFileInfo;
import 'package:wallet_ui/wallet_ui.dart';

/// The dialog is localization-agnostic: it renders using only the injected
/// [ExportLogsLabels], with no app l10n in scope.
const _labels = ExportLogsLabels(
  title: 'Export Logs',
  cancel: 'Cancel',
  exportError: 'No logs found to export.',
);

void main() {
  testWidgets('renders injected title and one row per log file', (tester) async {
    final files = [
      LogFileInfo(
        path: '/logs/log_2026-08-19.txt',
        name: 'log_2026-08-19.txt',
        modified: DateTime(2026, 8, 19),
        size: 2048,
      ),
      LogFileInfo(
        path: '/logs/log_2026-08-18.txt',
        name: 'log_2026-08-18.txt',
        modified: DateTime(2026, 8, 18),
        size: 512,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => ExportLogsDialog.show(context, files, _labels),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Injected labels are shown (no app l10n present).
    expect(find.text('Export Logs'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    // One row per file, with name and size.
    expect(find.text('log_2026-08-19.txt'), findsOneWidget);
    expect(find.text('log_2026-08-18.txt'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
  });

  testWidgets('the share is anchored to the row the user tapped', (tester) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    Map<Object?, Object?>? shareArgs;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'share') shareArgs = call.arguments as Map<Object?, Object?>;
      return 'com.apple.UIKit.activity.CopyToPasteboard';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );

    final files = [
      LogFileInfo(
        path: '/logs/log_2026-08-19.txt',
        name: 'log_2026-08-19.txt',
        modified: DateTime(2026, 8, 19),
        size: 2048,
      ),
      LogFileInfo(
        path: '/logs/log_2026-08-18.txt',
        name: 'log_2026-08-18.txt',
        modified: DateTime(2026, 8, 18),
        size: 512,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => ExportLogsDialog.show(context, files, _labels),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final row = find.text('log_2026-08-18.txt');
    final expected = tester.getRect(find.ancestor(of: row, matching: find.byType(ListTile)));
    await tester.tap(row);
    await tester.pumpAndSettle();

    // iOS refuses a share it cannot anchor, and an itemBuilder's context
    // measures the enclosing sliver rather than the row -- which yields no
    // origin at all, and an export that fails instead of opening the sheet.
    expect(shareArgs, isNotNull, reason: 'the share never reached the platform');
    expect(shareArgs!['originWidth'], expected.width);
    expect(shareArgs!['originHeight'], expected.height);
    expect(shareArgs!['originX'], expected.left);
    expect(shareArgs!['originY'], expected.top);
    expect(expected.isEmpty, isFalse);
  });
}
