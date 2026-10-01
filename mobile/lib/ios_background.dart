import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS suspends an app shortly after it leaves the screen, which closes the
/// connections to the PCs. The native side (ios/Runner/BackgroundKeepAlive.swift)
/// can keep the app running by playing silent audio while it is in the
/// background; this turns that on or off. No-op on other platforms.
const MethodChannel _channel = MethodChannel('ccnotify/background');

Future<void> setIosKeepAlive(bool enabled) async {
  if (!Platform.isIOS) return;
  try {
    await _channel.invokeMethod<void>('setKeepAlive', enabled);
  } catch (e) {
    debugPrint('ccnotify: setKeepAlive failed: $e');
  }
}
