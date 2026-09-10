import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart' show LogFileInfo;
import 'package:wallet_ui/wallet_ui.dart';

/// The dialog is localization-agnostic: it renders using only the injected
/// [ExportLogsLabels], with no app l10n in scope. Sharing itself hits the
/// share_plus plugin, which has no platform channel under `flutter test`, so the
/// test covers rendering only.
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
}
