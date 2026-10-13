import 'package:camera/camera.dart' show FlashMode;
import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../design/brand.dart';
import '../design/brand_screen_header.dart';
import '../design/toast.dart';

/// Full-bleed QR camera scanner with a floating brand header and a reliable
/// torch toggle. Presentational only — it owns the camera/torch UI and calls
/// [onResult] once with the first non-empty scan; the app decides what to do
/// with the result (e.g. `Navigator.pop`).
///
/// [accept], when given, gates the scan: a code it rejects is ignored and the
/// camera keeps scanning instead of returning it, so an unexpected QR never pops
/// the caller. [invalidMessage], when given, is shown (throttled) on a reject.
class ScanQrView extends StatefulWidget {
  final String title;
  final ValueChanged<String> onResult;
  final VoidCallback onBack;
  final bool Function(String text)? accept;
  final String? invalidMessage;

  const ScanQrView({
    super.key,
    required this.title,
    required this.onResult,
    required this.onBack,
    this.accept,
    this.invalidMessage,
  });

  @override
  State<ScanQrView> createState() => _ScanQrViewState();
}

class _ScanQrViewState extends State<ScanQrView> {
  bool _hasScanned = false;
  CameraController? _camera;
  bool _torchOn = false;
  bool _torchAvailable = false;
  bool _torchBusy = false;

  DateTime? _lastInvalidAt;

  void _onScan(Code result) {
    if (_hasScanned) return;

    final text = result.text;
    if (text == null || text.isEmpty) return;

    // An unexpected code is ignored so the camera keeps scanning — it must not
    // pop the caller with something it can't use.
    if (widget.accept != null && !widget.accept!(text)) {
      _notifyInvalid();
      return;
    }

    _hasScanned = true;
    widget.onResult(text);
  }

  // Throttled: the scanner fires per frame, so a bad code in view would spam.
  void _notifyInvalid() {
    final message = widget.invalidMessage;
    if (message == null) return;
    final now = DateTime.now();
    if (_lastInvalidAt != null && now.difference(_lastInvalidAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastInvalidAt = now;
    showBrandToast(context, message);
  }

  void _onControllerCreated(CameraController? controller, Exception? error) {
    // A fresh controller starts with the flash off (the widget sets it on init),
    // and a camera flip creates a new one — track it and reset our state. The
    // front camera has no torch, so only offer the button on the back one.
    _camera = controller;
    if (mounted) {
      setState(() {
        _torchOn = false;
        _torchAvailable = controller?.description.lensDirection == CameraLensDirection.back;
      });
    }
  }

  // The package's own flash button calls setFlashMode without awaiting it and
  // swallows the exception, so a tap while the camera is busy silently no-ops —
  // "keep tapping until it works". Drive it ourselves: await, catch, and debounce
  // concurrent taps so each tap reliably flips the torch.
  Future<void> _toggleTorch() async {
    final cam = _camera;
    if (cam == null || _torchBusy) return;
    _torchBusy = true;
    final next = !_torchOn;
    try {
      if (next) {
        // CameraX leaves a stale torchEnabled flag after a camera flip, so
        // setFlashMode(torch) no-ops; clearing to off first forces the enable.
        await cam.setFlashMode(FlashMode.off);
      }
      await cam.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } catch (_) {
      // Transient failure — leave the state unchanged so the icon keeps matching
      // the actual torch.
    } finally {
      _torchBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // ReaderWidget centres its scan square using the full screen size, so it
    // must be full-bleed; the brand header floats over its dimmed top band.
    return Scaffold(
      backgroundColor: BrandColors.ink,
      body: Stack(
        children: [
          Positioned.fill(
            child: ReaderWidget(
              onScan: _onScan,
              onControllerCreated: _onControllerCreated,
              // Our own torch (below) replaces the package's flaky flash button,
              // and sits just left of the flip-camera button, which we nudge
              // right to make room when the torch is shown.
              showFlashlight: false,
              showGallery: false,
              actionButtonsPadding: _torchAvailable
                  ? const EdgeInsets.only(left: 66, bottom: 10)
                  : const EdgeInsets.all(10),
              cropPercent: 1.0,
              tryHarder: true,
              scanDelay: const Duration(milliseconds: 200),
            ),
          ),
          if (_torchAvailable)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ColoredBox(
                      color: Colors.black,
                      child: IconButton(
                        onPressed: _toggleTorch,
                        color: Colors.white,
                        icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Align(
                alignment: Alignment.topCenter,
                child: BrandScreenHeader(
                  onBack: widget.onBack,
                  center: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: BrandColors.card,
                      borderRadius: BrandRadii.rPill,
                      border: Border.all(color: BrandColors.border),
                    ),
                    child: Text(
                      widget.title,
                      style: BrandText.appBar.copyWith(fontSize: 16, color: BrandColors.ink),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
