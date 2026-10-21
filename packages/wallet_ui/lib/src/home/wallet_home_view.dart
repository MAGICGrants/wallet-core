import 'package:flutter/material.dart';

import '../design/action_button.dart';
import '../design/brand.dart';

/// The mobile home screen both apps share, as a column of optional sections in
/// a fixed order: header, a notice, balance, actions, incoming payments,
/// accounts, the balance chart, then the security checklist.
///
/// The apps differ only in what they put in the slots. Spice fills [accounts]
/// with its chain cards and gives the balance an allocation bar; Skylight, with
/// one coin, leaves those out. A null slot is skipped along with its spacing.
class WalletHomeView extends StatelessWidget {
  final Widget header;

  /// Something the user must act on (a server still waiting to approve the
  /// wallet), above everything else.
  final Widget? notice;
  final Widget? balance;
  final Widget actions;
  final Widget? incoming;
  final Widget? accounts;
  final Widget? chart;
  final Widget? checklist;
  final Widget bottomNavigationBar;

  const WalletHomeView({
    super.key,
    required this.header,
    required this.actions,
    required this.bottomNavigationBar,
    this.notice,
    this.balance,
    this.incoming,
    this.accounts,
    this.chart,
    this.checklist,
  });

  @override
  Widget build(BuildContext context) {
    final sections = [?notice, ?balance, actions, ?incoming, ?accounts, ?chart, ?checklist];
    return Scaffold(
      backgroundColor: BrandColors.paper,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      BrandSpacing.lg,
                      BrandSpacing.xl,
                      BrandSpacing.lg,
                      BrandSpacing.xxl,
                    ),
                    children: [
                      for (var i = 0; i < sections.length; i++) ...[
                        if (i > 0) const SizedBox(height: 20),
                        sections[i],
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's logo and name, above the balance.
class HomeHeader extends StatelessWidget {
  final Widget logo;
  final String title;

  /// Defaults to ink; Spice sets its title in the deep primary.
  final Color? titleColor;

  const HomeHeader({super.key, required this.logo, required this.title, this.titleColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 16, bottom: 2),
      child: Row(
        children: [
          logo,
          const SizedBox(width: 10),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 18,
              height: 1,
              color: titleColor ?? BrandColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// Receive, Send and Swap. Swap is not built yet, so [onSwap] only says so.
class HomeActionRow extends StatelessWidget {
  final String receiveLabel;
  final String sendLabel;
  final String swapLabel;
  final VoidCallback? onReceive;
  final VoidCallback? onSend;
  final VoidCallback onSwap;

  const HomeActionRow({
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
      spacing: 10,
      children: [
        Expanded(
          child: ActionButton(
            icon: Icons.arrow_downward,
            label: receiveLabel,
            onPressed: onReceive,
          ),
        ),
        Expanded(
          child: ActionButton(icon: Icons.arrow_upward, label: sendLabel, onPressed: onSend),
        ),
        Expanded(
          child: ActionButton(icon: Icons.swap_horiz, label: swapLabel, onPressed: onSwap),
        ),
      ],
    );
  }
}
