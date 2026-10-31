import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../design/brand.dart';
import '../design/settings_group.dart';
import '../design/sub_page.dart';

/// One package's entries in [LicenseRegistry]; a package can carry several
/// (the Flutter engine carries dozens).
class PackageLicenses {
  const PackageLicenses(this.package, this.entries);

  final String package;
  final List<LicenseEntry> entries;
}

/// Every package in [LicenseRegistry] with its entries, sorted by name. An entry
/// naming several packages is listed under each. The text is parsed only when a
/// package is opened ([LicenseTextView]).
Future<List<PackageLicenses>> loadPackageLicenses() async {
  final byPackage = <String, List<LicenseEntry>>{};
  await for (final entry in LicenseRegistry.licenses) {
    for (final package in entry.packages) {
      (byPackage[package] ??= []).add(entry);
    }
  }
  final names = byPackage.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [for (final name in names) PackageLicenses(name, byPackage[name]!)];
}

/// The packages as one settings group, each row opening its licenses.
class LicensePackageList extends StatelessWidget {
  final List<PackageLicenses> packages;
  final ValueChanged<PackageLicenses> onOpen;

  const LicensePackageList({super.key, required this.packages, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      tiles: [for (final p in packages) SettingsNavTile(title: p.package, onTap: () => onOpen(p))],
    );
  }
}

/// One package's license texts, set like the license notice in the Terms of
/// Service. Each entry is parsed off the frame budget, as Flutter's own license
/// page does: the engine's run to thousands of paragraphs.
class LicenseTextView extends StatefulWidget {
  final PackageLicenses package;
  final EdgeInsetsGeometry padding;

  const LicenseTextView({super.key, required this.package, this.padding = EdgeInsets.zero});

  @override
  State<LicenseTextView> createState() => _LicenseTextViewState();
}

class _LicenseTextViewState extends State<LicenseTextView> {
  // Every paragraph in order, with null between two entries.
  final _items = <LicenseParagraph?>[];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final entry in widget.package.entries) {
      final paragraphs = await SchedulerBinding.instance.scheduleTask(
        entry.paragraphs.toList,
        Priority.animation,
        debugLabel: 'License',
      );
      if (!mounted) return;
      setState(() {
        if (_items.isNotEmpty) _items.add(null);
        _items.addAll(paragraphs);
      });
    }
    if (mounted) setState(() => _loaded = true);
  }

  Widget _paragraph(LicenseParagraph p) {
    final style = TextStyle(
      fontFamily: 'Ubuntu Mono',
      fontSize: 13,
      height: 1.4,
      color: BrandColors.ink,
    );
    if (p.indent == LicenseParagraph.centeredIndent) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          p.text,
          textAlign: TextAlign.center,
          style: style.copyWith(fontWeight: FontWeight.w700),
        ),
      );
    }
    return Padding(
      padding: EdgeInsetsDirectional.only(top: 10, start: 16.0 * p.indent),
      child: Text(p.text, style: style),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: widget.padding,
      itemCount: _items.length + (_loaded ? 0 : 1),
      itemBuilder: (context, i) {
        if (i == _items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: BrandColors.primary),
              ),
            ),
          );
        }
        final p = _items[i];
        if (p == null) return Divider(height: 36, thickness: 1, color: BrandColors.hairline);
        return _paragraph(p);
      },
    );
  }
}

/// The packages the app ships and their licenses. One route: opening a package
/// swaps the list for its text, and back returns to the list.
class OpenSourceLicensesScreen extends StatefulWidget {
  final String title;
  final SubPageChrome chrome;

  const OpenSourceLicensesScreen({super.key, required this.title, required this.chrome});

  @override
  State<OpenSourceLicensesScreen> createState() => _OpenSourceLicensesScreenState();
}

class _OpenSourceLicensesScreenState extends State<OpenSourceLicensesScreen> {
  final _packages = loadPackageLicenses();
  PackageLicenses? _open;

  Widget _list() {
    return FutureBuilder<List<PackageLicenses>>(
      future: _packages,
      builder: (context, snapshot) {
        final packages = snapshot.data;
        if (packages == null) {
          return Center(child: CircularProgressIndicator(color: BrandColors.primary));
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: LicensePackageList(packages: packages, onOpen: (p) => setState(() => _open = p)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    return PopScope(
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _open = null);
      },
      child: SubPageScaffold(
        title: open?.package ?? widget.title,
        chrome: widget.chrome,
        backLabel: open != null ? widget.title : null,
        onBack: open != null ? () => setState(() => _open = null) : null,
        child: open == null
            ? _list()
            : LicenseTextView(
                key: ValueKey(open.package),
                package: open,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              ),
      ),
    );
  }
}
