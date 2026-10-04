import 'package:flutter/material.dart';

/// Closes the on-screen keyboard. Takes no room while the keyboard is hidden
/// (the iOS keyboard has no key of its own for that).
class KeyboardHideButton extends StatefulWidget {
  const KeyboardHideButton({super.key});

  @override
  State<KeyboardHideButton> createState() => _KeyboardHideButtonState();
}

class _KeyboardHideButtonState extends State<KeyboardHideButton> with WidgetsBindingObserver {
  bool _keyboardUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardUp = _isKeyboardUp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Asked from the view: inside a Scaffold's body, MediaQuery no longer
  /// knows about the keyboard (the body was already made smaller for it).
  bool _isKeyboardUp() => View.of(context).viewInsets.bottom > 0;

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final up = _isKeyboardUp();
    if (up != _keyboardUp) setState(() => _keyboardUp = up);
  }

  @override
  Widget build(BuildContext context) {
    if (!_keyboardUp) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Hide keyboard',
      onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
      icon: const Icon(Icons.keyboard_hide_outlined),
    );
  }
}
