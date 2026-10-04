import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';

/// Voice messages: the phone records, turns the recording into text on the
/// device and hands the text back (ios/Runner/VoiceInput.swift). iOS only for
/// now; elsewhere [supported] is false and the chat shows no microphone.
class VoiceInput {
  static const MethodChannel _channel = MethodChannel('mewo-on-fire/voice');

  /// Same limit as the native side.
  static const Duration maxLength = Duration(seconds: 120);

  /// Language codes and their names, as shown on the language button.
  static const Map<String, String> languages = <String, String>{
    'en-US': 'English',
    'ar-SA': 'العربية',
  };

  static bool get supported => Platform.isIOS;

  /// [setting] (`AppSettings.voiceLanguage`), or the phone's language when
  /// it is not set.
  static String languageFor(String setting) {
    if (languages.containsKey(setting)) return setting;
    return PlatformDispatcher.instance.locale.languageCode == 'ar' ? 'ar-SA' : 'en-US';
  }

  static String other(String language) => language == 'ar-SA' ? 'en-US' : 'ar-SA';

  /// Starts recording (asks for the microphone and speech recognition the
  /// first time). Throws a [PlatformException]; see [errorText].
  static Future<void> start() => _channel.invokeMethod<void>('start');

  /// Stops and returns what was said in [language].
  static Future<String> stop(String language) async =>
      await _channel.invokeMethod<String>('stop', language) ?? '';

  /// The last recording once more, heard as [language].
  static Future<String> again(String language) async =>
      await _channel.invokeMethod<String>('again', language) ?? '';

  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {}
  }

  static String errorText(Object error) {
    switch (error is PlatformException ? error.code : '') {
      case 'mic_denied':
        return 'Allow the microphone for Mewo on Fire in the Settings app';
      case 'speech_denied':
        return 'Allow Speech Recognition for Mewo on Fire in the Settings app';
      case 'speech_unavailable':
        return 'This language cannot be recognized right now';
      case 'too_short':
        return 'That was too short';
      case 'no_speech':
        return 'Could not make out any words';
      default:
        return 'Could not record';
    }
  }
}
