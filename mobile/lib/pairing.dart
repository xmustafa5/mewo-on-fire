import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'models.dart';
import 'pc_link.dart';

/// Pairing failure with a message that can be shown to the user as-is.
class PairingException implements Exception {
  const PairingException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Human-readable device name, e.g. "Google Pixel 8" / "Samsung SM-S911B".
Future<String> deviceName() async {
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      var maker = a.manufacturer.trim();
      final model = a.model.trim();
      if (maker.isNotEmpty) maker = maker[0].toUpperCase() + maker.substring(1);
      if (maker.isEmpty) return model.isEmpty ? 'Android phone' : model;
      if (model.toLowerCase().startsWith(maker.toLowerCase())) return model;
      return '$maker $model';
    }
    if (Platform.isIOS) {
      final i = await info.iosInfo;
      return i.name.isNotEmpty ? i.name : i.model;
    }
  } catch (_) {}
  return 'Phone';
}

String _errorText(Object? code) {
  switch (code) {
    case 'invalid_code':
      return 'The pairing code is invalid or has expired (codes are single-use and '
          'valid for 5 minutes). Run `ccnotify pair` on the PC again.';
    case 'unauthorized':
      return 'The PC rejected this phone.';
    default:
      return 'The PC refused pairing (${code ?? 'unknown error'}).';
  }
}

/// Runs the one-shot pairing exchange (PROTOCOL.md "Pairing") against the
/// hosts in [qr], in order, with certificate pinning on `qr.fp`.
Future<PairedPc> pairWithPc(QrPayload qr) async {
  final name = await deviceName();
  String? lastError;

  for (final host in qr.hosts) {
    final client = pinnedHttpClient(qr.fp);
    WebSocket? ws;
    try {
      ws = await WebSocket.connect(wssUrl(host, qr.port), customClient: client)
          .timeout(const Duration(seconds: 10));
      ws.add(jsonEncode({'type': 'pair', 'code': qr.code, 'device_name': name}));
      final Object? reply = await ws
          .firstWhere((d) => d is String)
          .timeout(const Duration(seconds: 10));
      final Object? msg = jsonDecode(reply as String);
      if (msg is! Map) throw const PairingException('Unexpected reply from the PC.');
      final type = msg['type'];
      if (type == 'error') throw PairingException(_errorText(msg['error']));
      if (type != 'paired') throw const PairingException('Unexpected reply from the PC.');

      final token = msg['token'];
      final deviceId = msg['device_id'];
      if (token is! String || token.isEmpty) {
        throw const PairingException('The PC did not return an access token.');
      }
      final pcId = msg['pc_id'] is String && (msg['pc_id'] as String).isNotEmpty
          ? msg['pc_id'] as String
          : qr.id;
      final pcName =
          msg['name'] is String && (msg['name'] as String).isNotEmpty ? msg['name'] as String : qr.name;
      final lastId = msg['last_id'];
      return PairedPc(
        id: pcId,
        name: pcName,
        hosts: qr.hosts,
        port: qr.port,
        fp: qr.fp,
        token: token,
        deviceId: deviceId is String ? deviceId : '$deviceId',
        initialSince: lastId is int ? lastId : (lastId is num ? lastId.toInt() : 0),
      );
    } on PairingException {
      rethrow;
    } on TlsException {
      lastError = "The PC's certificate does not match the QR code. "
          'Run `ccnotify pair` again and scan the new code.';
    } on TimeoutException {
      lastError = 'Timed out talking to $host:${qr.port}. Make sure the phone is on the '
          'same network as the PC and the ccnotify daemon is running.';
    } on SocketException catch (e) {
      final reason = e.osError?.message ?? e.message;
      lastError = "Can't reach $host:${qr.port} ($reason). Make sure the phone is on the "
          'same network as the PC and the ccnotify daemon is running.';
    } on WebSocketException catch (e) {
      lastError = 'Connection to the PC failed: ${e.message}';
    } on StateError {
      lastError = 'The PC closed the connection without answering.';
    } on FormatException {
      lastError = 'The PC sent an invalid reply.';
    } catch (e) {
      lastError = 'Pairing failed: $e';
    } finally {
      if (ws != null) {
        try {
          unawaited(ws.close().then((_) {}, onError: (_) {}));
        } catch (_) {}
      }
      client.close(force: true);
    }
  }
  throw PairingException(lastError ?? 'Could not reach the PC.');
}
