import 'package:flutter/material.dart';
import 'package:wallet_domain/wallet_domain.dart' show CryptoWallet;

import '../design/brand.dart';
import '../design/route_pill.dart';
import 'connection_address.dart';

/// The route/security pills implied by a connection: a routing pill (TOR/PROXY)
/// when either is in use, then a security pill (HTTPS for a clearnet domain,
/// LOCAL for a LAN host). Empty for a plain public-IP node, which is neither.
/// The pure [RoutePill] widget + [RoutePillIcon] enum live in the design layer.
List<RoutePill> connectionRoutePills({
  required bool useTor,
  required String proxyPort,
  required String address,
  bool compact = false,
}) {
  final pills = <RoutePill>[];
  if (useTor) {
    pills.add(
      RoutePill(
        label: 'TOR',
        color: BrandColors.purple,
        bg: BrandColors.purpleBg,
        icon: RoutePillIcon.tor,
        compact: compact,
      ),
    );
  } else if (proxyPort.trim().isNotEmpty) {
    pills.add(
      RoutePill(
        label: 'PROXY',
        color: BrandColors.blue,
        bg: BrandColors.blueBg,
        icon: RoutePillIcon.proxy,
        compact: compact,
      ),
    );
  }
  if (addressUsesSsl(address)) {
    pills.add(
      RoutePill(
        label: 'HTTPS',
        color: BrandColors.success,
        bg: BrandColors.successBg,
        icon: RoutePillIcon.https,
        compact: compact,
      ),
    );
  } else if (addressIsLocal(address)) {
    pills.add(
      RoutePill(
        label: 'LOCAL',
        color: BrandColors.inkFaint,
        bg: BrandColors.surfaceMuted,
        icon: RoutePillIcon.local,
        compact: compact,
      ),
    );
  }
  return pills;
}

/// A wallet's connection as pills: transport (TOR/PROXY · HTTPS/LOCAL) then the
/// orange server-kind pill (NODE / LWS) last. Wraps to a new line in tight rows.
/// Renders nothing when there are no pills (e.g. an unconfigured coin).
class ConnectionPills extends StatelessWidget {
  final CryptoWallet wallet;

  /// Icon-only pills on a single non-wrapping row (used beside "x blocks left").
  final bool compact;

  const ConnectionPills({super.key, required this.wallet, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final typePill = connectionTypePill(wallet, compact: compact);
    final pills = <Widget>[
      ...connectionRoutePills(
        useTor: wallet.connectionUseTor,
        proxyPort: wallet.connectionProxyPort,
        address: wallet.connectionAddress,
        compact: compact,
      ),
      ?typePill,
    ];
    if (pills.isEmpty) return const SizedBox.shrink();
    return compact
        ? Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: pills)
        : Wrap(spacing: 6, runSpacing: 6, children: pills);
  }
}

/// The server-kind pill, meant to sit last after the route pills. Bitcoin always
/// speaks Electrum (light-blue pill); Monero shows its mode (orange NODE / LWS).
/// Null for coins with no such distinction (e.g. Ethereum's RPC).
RoutePill? connectionTypePill(CryptoWallet wallet, {bool compact = false}) {
  if (wallet.coinSymbol == 'BTC' || wallet.coinSymbol == 'TBTC') {
    return RoutePill(
      label: 'ELECTRUM',
      color: BrandColors.electrum,
      bg: BrandColors.electrumBg,
      icon: RoutePillIcon.electrum,
      compact: compact,
    );
  }
  final label = switch (wallet.connectionType) {
    'node' => 'NODE',
    'lws' => 'LWS',
    _ => null,
  };
  if (label == null) return null;
  return RoutePill(
    label: label,
    color: BrandColors.orange,
    bg: BrandColors.orangeBg,
    icon: RoutePillIcon.server,
    compact: compact,
  );
}
