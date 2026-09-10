import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum RoutePillIcon { tor, https, proxy, local, server, electrum }

/// Small route/security pill (TOR · HTTPS · PROXY · LOCAL · ELECTRUM · NODE/LWS).
/// Icons are the exact design line marks, tinted to the pill colour. Pure: the
/// caller supplies label/color/bg/icon. The connection-aware pill builders that
/// derive these from a wallet live in the wallet layer.
class RoutePill extends StatelessWidget {
  final String label;
  final Color color;
  final Color bg;
  final RoutePillIcon icon;

  /// Icon only, no label — a tighter pill for the syncing row.
  final bool compact;

  const RoutePill({
    super.key,
    required this.label,
    required this.color,
    required this.bg,
    required this.icon,
    this.compact = false,
  });

  String _svg() {
    final hex = '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    switch (icon) {
      case RoutePillIcon.tor:
        return '<svg viewBox="0 0 24 24" fill="none" stroke="$hex" stroke-width="2">'
            '<circle cx="12" cy="12" r="8.5"/><ellipse cx="12" cy="12" rx="3.6" ry="8.5"/>'
            '<path d="M3.5 12h17"/></svg>';
      case RoutePillIcon.https:
        return '<svg viewBox="0 0 24 24" fill="none" stroke="$hex" stroke-width="2.2" stroke-linecap="round">'
            '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>';
      case RoutePillIcon.proxy:
        return '<svg viewBox="0 0 24 24" fill="none" stroke="$hex" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">'
            '<path d="M4 12h4M16 12h4"/><circle cx="12" cy="12" r="3.2"/></svg>';
      case RoutePillIcon.local:
        return '<svg viewBox="0 0 24 24" fill="none" stroke="$hex" stroke-width="2.2" stroke-linecap="round">'
            '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7.5a4 4 0 0 1 7-2.6"/></svg>';
      case RoutePillIcon.server:
        return '<svg viewBox="0 0 24 24" fill="none" stroke="$hex" stroke-width="2" stroke-linecap="round">'
            '<rect x="4" y="5" width="16" height="6" rx="1.6"/><rect x="4" y="13" width="16" height="6" rx="1.6"/>'
            '<path d="M7.5 8h.01M7.5 16h.01"/></svg>';
      case RoutePillIcon.electrum:
        // A generic atom (nucleus + electron orbits) for the Electrum server pill
        // — no official logo asset is bundled.
        return '<svg viewBox="0 0 24 24" fill="none" stroke="$hex" stroke-width="1.5">'
            '<circle cx="12" cy="12" r="1.7" fill="$hex" stroke="none"/>'
            '<ellipse cx="12" cy="12" rx="10" ry="4.3"/>'
            '<ellipse cx="12" cy="12" rx="10" ry="4.3" transform="rotate(60 12 12)"/>'
            '<ellipse cx="12" cy="12" rx="10" ry="4.3" transform="rotate(120 12 12)"/></svg>';
    }
  }

  @override
  Widget build(BuildContext context) {
    final glyph = SvgPicture.string(_svg(), width: 10.5, height: 10.5);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: 4.5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6.5)),
      child: compact
          ? glyph
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                glyph,
                const SizedBox(width: 4.5),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Ubuntu Mono',
                    fontSize: 9,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.74,
                    color: color,
                  ),
                ),
              ],
            ),
    );
  }
}
