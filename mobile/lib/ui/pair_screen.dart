import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_state.dart';
import '../models.dart';
import '../pairing.dart';
import 'theme/ember.dart';
import 'theme/flame.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

class PairScreen extends StatefulWidget {
  const PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  bool _busy = false;
  String? _error;
  String? _pairingWith;
  String? _lastRaw; // ignore repeated detections of a code that already failed

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_busy) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;
      if (raw == _lastRaw) return;
      _lastRaw = raw;
      _pair(raw);
      return;
    }
  }

  Future<void> _pair(String raw) async {
    if (_busy) return;
    QrPayload qr;
    try {
      qr = QrPayload.parse(raw);
    } on FormatException catch (e) {
      HapticFeedback.heavyImpact();
      setState(() => _error = e.message);
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _error = null;
      _pairingWith = qr.name;
    });
    try {
      final pc = await pairWithPc(qr);
      await AppState.instance.addPc(pc);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text('Paired with ${pc.name}')));
    } catch (e) {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _busy = false;
        _error = e is PairingException ? e.message : 'Pairing failed: $e';
      });
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _lastRaw = null;
    });
  }

  Future<void> _pasteCode() async {
    final textCtrl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste pairing code'),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          // iOS would turn the quotes into typographic ones and "id" into "I'd".
          autocorrect: false,
          enableSuggestions: false,
          smartQuotesType: SmartQuotesType.disabled,
          smartDashesType: SmartDashesType.disabled,
          decoration: const InputDecoration(
            hintText: '{"v":1,"id":"…","code":"…"}',
            helperText: 'The QR payload line printed by `mewo pair`.',
          ),
          style: TextStyle(fontFamily: Ember.mono(context), fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, textCtrl.text),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    textCtrl.dispose();
    if (raw == null || raw.trim().isEmpty) return;
    _lastRaw = null;
    await _pair(raw);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Ember.bg,
      extendBodyBehindAppBar: true,
      appBar: const GlassTopBar(title: Text('Pair a PC'), subtitle: Text('Scan the QR code from `mewo pair`')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => ColoredBox(
              color: Ember.bg,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? 'Camera permission denied. Allow camera access in system settings, '
                            'or use "Paste code" below.'
                        : 'Camera unavailable (${error.errorCode.name}). Use "Paste code" below.',
                    textAlign: TextAlign.center,
                    style: t.bodyMedium?.copyWith(color: Ember.text2),
                  ),
                ),
              ),
            ),
          ),
          // Darken the edges so the bars and the viewfinder read well.
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xB30C0A09), Color(0x000C0A09), Color(0x000C0A09), Color(0xCC0C0A09)],
                  stops: [0, 0.3, 0.6, 1],
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 60),
                child: _Viewfinder(active: !_busy && _error == null),
              ),
            ),
          ),
          if (_busy)
            Positioned.fill(
              child: FadeSlideIn(
                offset: Offset.zero,
                child: ColoredBox(
                  color: Ember.scrim,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const FlameMark(size: 64),
                        const SizedBox(height: 20),
                        Text('Pairing with ${_pairingWith ?? 'PC'}…', style: t.titleMedium),
                        const SizedBox(height: 6),
                        Text('Checking the certificate and the code', style: t.bodySmall?.copyWith(color: Ember.text2)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GlassBar(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: const Border(top: BorderSide(color: Ember.lineStrong)),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: AnimatedSize(
                    duration: Motion.base,
                    curve: Motion.easeOut,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_error != null) ...[
                          GlassCard(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            radius: 16,
                            fill: const Color(0xFF2A1618).withValues(alpha: 0.95),
                            borderColor: Ember.danger.withValues(alpha: 0.5),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline_rounded, size: 20, color: Ember.danger),
                                const SizedBox(width: 12),
                                Expanded(child: Text(_error!, style: t.bodySmall?.copyWith(color: Ember.text))),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          EmberButton(
                            label: 'Scan again',
                            icon: Icons.refresh_rounded,
                            expand: true,
                            onPressed: _busy ? null : _retry,
                          ),
                        ] else ...[
                          Text(
                            'On your PC, run `mewo pair` and point the camera at the QR code.',
                            style: t.bodyMedium?.copyWith(color: Ember.text2),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 10),
                        EmberButton(
                          label: 'Paste the code instead',
                          icon: Icons.content_paste_rounded,
                          style: EmberButtonStyle.ghost,
                          expand: true,
                          onPressed: _busy ? null : _pasteCode,
                        ),
                      ],
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

/// Four fire corners that breathe, with a scan line sweeping between them.
class _Viewfinder extends StatefulWidget {
  const _Viewfinder({required this.active});
  final bool active;

  @override
  State<_Viewfinder> createState() => _ViewfinderState();
}

class _ViewfinderState extends State<_Viewfinder> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Viewfinder old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.active && !reducedMotion(context);
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final breath = 1 + 0.015 * math.sin(_c.value * 2 * math.pi);
        return Transform.scale(
          scale: breath,
          child: CustomPaint(
            size: const Size(250, 250),
            painter: _ViewfinderPainter(_c.value, scanning: widget.active),
          ),
        );
      },
    );
  }
}

class _ViewfinderPainter extends CustomPainter {
  const _ViewfinderPainter(this.t, {required this.scanning});
  final double t;
  final bool scanning;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const r = 26.0;
    const len = 38.0;
    final paint = Paint()
      ..shader = Ember.fire.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final glow = Paint()
      ..color = Ember.flame.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    Path corner(Offset o, double sx, double sy) {
      // Two legs of length [len] meeting in a rounded corner at [o].
      final p = Path();
      p.moveTo(o.dx, o.dy + sy * len);
      p.lineTo(o.dx, o.dy + sy * r);
      p.quadraticBezierTo(o.dx, o.dy, o.dx + sx * r, o.dy);
      p.lineTo(o.dx + sx * len, o.dy);
      return p;
    }

    final corners = [
      corner(rect.topLeft, 1, 1),
      corner(rect.topRight, -1, 1),
      corner(rect.bottomRight, -1, -1),
      corner(rect.bottomLeft, 1, -1),
    ];
    for (final c in corners) {
      canvas.drawPath(c, glow);
      canvas.drawPath(c, paint);
    }

    if (scanning) {
      // The line sweeps down, then back up.
      final phase = t < 0.5 ? t * 2 : 2 - t * 2;
      final y = 20 + (size.height - 40) * Curves.easeInOut.transform(phase);
      final line = Paint()
        ..shader = LinearGradient(
          colors: [Ember.amber.withValues(alpha: 0), Ember.amber, Ember.amber.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, y - 1, size.width, 2))
        ..strokeWidth = 2;
      canvas.drawLine(Offset(16, y), Offset(size.width - 16, y), line);
      canvas.drawRect(
        Rect.fromLTWH(16, y - 14, size.width - 32, 14),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Ember.amber.withValues(alpha: 0), Ember.amber.withValues(alpha: 0.18)],
          ).createShader(Rect.fromLTWH(0, y - 14, size.width, 14)),
      );
    }
  }

  @override
  bool shouldRepaint(_ViewfinderPainter old) => old.t != t || old.scanning != scanning;
}
