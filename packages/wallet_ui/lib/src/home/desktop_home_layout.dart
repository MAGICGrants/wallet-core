import 'package:flutter/material.dart';

import '../design/brand_button.dart';

/// The desktop home both apps share, inside the app's sidebar shell: the
/// balance with its actions across the top, then the cards in a [wide] column
/// beside a narrow [side] one, then whatever should span the [full] width.
///
/// The same cards as the mobile [WalletHomeView]; only the arrangement is
/// desktop's. With no [side] card (the checklist hides once done) the wide
/// column takes the whole width, and a narrow window stacks the two.
class DesktopHomeLayout extends StatelessWidget {
  final Widget balance;
  final Widget actions;

  /// Top right, above the balance: the sync pill.
  final Widget? status;
  final List<Widget> wide;
  final Widget? side;
  final List<Widget> full;

  const DesktopHomeLayout({
    super.key,
    required this.balance,
    required this.actions,
    this.status,
    this.wide = const [],
    this.side,
    this.full = const [],
  });

  static const _gap = 20.0;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(44, 36, 44, 36),
      children: [
        if (status != null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(padding: const EdgeInsets.only(bottom: 18), child: status),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: balance),
            const SizedBox(width: 24),
            actions,
          ],
        ),
        if (wide.isNotEmpty || side != null) ...[
          const SizedBox(height: 30),
          LayoutBuilder(builder: (context, constraints) => _columns(constraints.maxWidth)),
        ],
        for (final w in full) ...[const SizedBox(height: _gap), w],
      ],
    );
  }

  Widget _columns(double width) {
    final wideColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < wide.length; i++) ...[if (i > 0) const SizedBox(height: _gap), wide[i]],
      ],
    );
    final s = side;
    if (s == null) return wideColumn;
    if (wide.isEmpty) return s;
    // Too narrow for two columns: the side card goes under the others.
    if (width < 700) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          wideColumn,
          const SizedBox(height: _gap),
          s,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 155, child: wideColumn),
        const SizedBox(width: _gap),
        Expanded(flex: 100, child: s),
      ],
    );
  }
}

/// Receive, Send and Swap as the desktop's row of secondary buttons. Swap is
/// not built yet, so [onSwap] only says so.
class DesktopHomeActions extends StatelessWidget {
  final String receiveLabel;
  final String sendLabel;
  final String swapLabel;
  final VoidCallback? onReceive;
  final VoidCallback? onSend;
  final VoidCallback onSwap;

  const DesktopHomeActions({
    super.key,
    required this.receiveLabel,
    required this.sendLabel,
    required this.swapLabel,
    required this.onReceive,
    required this.onSend,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 10,
      children: [
        BrandButton.secondary(
          label: receiveLabel,
          icon: Icons.south_west,
          expand: false,
          onPressed: onReceive,
        ),
        BrandButton.secondary(
          label: sendLabel,
          icon: Icons.north_east,
          expand: false,
          onPressed: onSend,
        ),
        BrandButton.secondary(
          label: swapLabel,
          icon: Icons.swap_horiz,
          expand: false,
          onPressed: onSwap,
        ),
      ],
    );
  }
}
