import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_state.dart';
import '../models.dart';
import '../pairing.dart';

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
      setState(() => _error = e.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _pairingWith = qr.name;
    });
    try {
      final pc = await pairWithPc(qr);
      await AppState.instance.addPc(pc);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text('Paired with ${pc.name}')));
    } catch (e) {
      if (!mounted) return;
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
            border: OutlineInputBorder(),
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
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
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Pair a PC')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  // Black like the camera preview it replaces (the text is white).
                  errorBuilder: (context, error) => ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          error.errorCode == MobileScannerErrorCode.permissionDenied
                              ? 'Camera permission denied. Allow camera access in system settings, '
                                  'or use "Paste code" below.'
                              : 'Camera unavailable (${error.errorCode.name}). Use "Paste code" below.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
                // Simple viewfinder.
                IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.primary, width: 3),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                if (_busy)
                  Container(
                    color: Colors.black54,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          'Pairing with ${_pairingWith ?? 'PC'}…',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Scan again'),
                    ),
                  ] else
                    Text(
                      'Run `mewo pair` on your PC and point the camera at the QR code.',
                      style: t.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _busy ? null : _pasteCode,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Paste code instead'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
