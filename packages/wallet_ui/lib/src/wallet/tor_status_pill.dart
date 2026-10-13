import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart';

import '../design/brand.dart';

/// Labels for [TorStatusPill], injected so the package stays free of app l10n.
/// [off] is for Tor disabled by the user; [disconnected] is Tor enabled but not
/// reachable (bootstrap failed, or the external proxy is down). The `external*`
/// variants name the mode, e.g. "External Tor · connected".
class TorStatusLabels {
  final String connected, connecting, disconnected, off;
  final String externalConnected, externalConnecting, externalDisconnected;
  const TorStatusLabels({
    required this.connected,
    required this.connecting,
    required this.disconnected,
    required this.off,
    required this.externalConnected,
    required this.externalConnecting,
    required this.externalDisconnected,
  });
}

/// Desktop Tor-status pill: a coloured dot + label for the *effective* Tor
/// status. Built-in mode reads the embedded [TorService]; external mode is
/// user-managed, so its reachability is probed on a slow interval rather than
/// inheriting the built-in Tor's "connected"; disabled is off.
class TorStatusPill extends StatefulWidget {
  final TorStatusLabels labels;
  const TorStatusPill({super.key, required this.labels});

  @override
  State<TorStatusPill> createState() => _TorStatusPillState();
}

class _TorStatusPillState extends State<TorStatusPill> {
  // TorService exposes no change notification, so poll the effective status.
  Timer? _poll;
  // Starts optimistic so an enabled mode shows "connecting", not a red
  // "disconnected" flash, during the first poll.
  TorConnectionStatus _state = TorConnectionStatus.connecting;
  TorConnectionStatus _externalState = TorConnectionStatus.connecting;
  DateTime? _externalProbedAt;
  bool _externalProbing = false;
  TorMode? _lastMode;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _refresh() {
    final mode = TorSettingsService.sharedInstance.torMode;
    if (mode != _lastMode) {
      // On a switch into external, re-probe at once and drop a stale result.
      _lastMode = mode;
      _externalProbedAt = null;
      _externalState = TorConnectionStatus.connecting;
    }
    final TorConnectionStatus next;
    switch (mode) {
      case TorMode.disabled:
        next = TorConnectionStatus.disconnected;
      case TorMode.builtIn:
        next = TorService.sharedInstance.status;
      case TorMode.external:
        _maybeProbeExternal();
        next = _externalState;
    }
    if (mounted && next != _state) setState(() => _state = next);
  }

  void _maybeProbeExternal() {
    if (_externalProbing) return;
    final at = _externalProbedAt;
    if (at != null && DateTime.now().difference(at) < const Duration(seconds: 15)) return;
    _externalProbing = true;
    unawaited(() async {
      final reachable = await _externalProxyReachable();
      _externalProbedAt = DateTime.now();
      _externalProbing = false;
      _externalState = reachable ? TorConnectionStatus.connected : TorConnectionStatus.disconnected;
    }());
  }

  /// Opens a short-lived socket to the configured external SOCKS proxy; false if
  /// the port is unset/invalid (getProxy null) or nothing is listening.
  Future<bool> _externalProxyReachable() async {
    try {
      final proxy = await TorSettingsService.sharedInstance.getProxy();
      if (proxy == null) return false;
      final socket = await Socket.connect(
        proxy.host,
        proxy.port,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final mode = TorSettingsService.sharedInstance.torMode;
    // Disabled is a quiet "off"; enabled-but-down is a red "disconnected".
    // External labels name the mode ("External Tor").
    final Color color;
    final String text;
    if (mode == TorMode.disabled) {
      color = BrandColors.inkFaint;
      text = labels.off;
    } else if (mode == TorMode.external) {
      (color, text) = switch (_state) {
        TorConnectionStatus.connected => (BrandColors.purple, labels.externalConnected),
        TorConnectionStatus.connecting => (BrandColors.warning, labels.externalConnecting),
        TorConnectionStatus.disconnected => (BrandColors.error, labels.externalDisconnected),
      };
    } else {
      (color, text) = switch (_state) {
        TorConnectionStatus.connected => (BrandColors.purple, labels.connected),
        TorConnectionStatus.connecting => (BrandColors.warning, labels.connecting),
        TorConnectionStatus.disconnected => (BrandColors.error, labels.disconnected),
      };
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 9),
          Text(
            text,
            style: TextStyle(
              fontFamily: 'Ubuntu',
              fontSize: 12,
              height: 1,
              color: BrandColors.inkMuted,
            ),
          ),
        ],
      ),
    );
  }
}
