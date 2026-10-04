import 'dart:async';
import 'dart:io';

/// Reaches a PC through a relay (PROTOCOL.md v1.4), for when the phone is not
/// on the PC's network and the PC cannot be reached from the internet.
///
/// The relay only passes bytes. The connection that goes through it is the
/// usual one — TLS with the PC's pinned certificate, then the token — so it
/// is as private as on the LAN. To keep that code unchanged, the tunnel
/// listens on a local port: whatever connects to `127.0.0.1:[port]` is
/// talking to the PC.
class RelayTunnel {
  RelayTunnel._(this._server, this._relay);

  final ServerSocket _server;
  final WebSocket _relay;
  Socket? _local;
  bool _closed = false;

  int get port => _server.port;

  /// Whether [host] (an entry of a PC's `hosts`) is a relay rather than an
  /// address: `wss://relay.example`.
  static bool isRelay(String host) => host.startsWith('wss://') || host.startsWith('ws://');

  /// Connects to [relay] for the PC [pcId]. Throws when the relay cannot be
  /// reached or the PC is not connected to it.
  static Future<RelayTunnel> open(String relay, String pcId, {required Duration timeout}) async {
    final ws = await WebSocket.connect('$relay/pc/$pcId/connect').timeout(timeout);
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    } catch (_) {
      unawaited(ws.close().catchError((Object _) {}));
      rethrow;
    }
    return RelayTunnel._(server, ws).._start();
  }

  void _start() {
    // From the PC before the local side is connected (TLS has the client
    // speak first, so normally nothing).
    final early = <List<int>>[];
    _relay.listen(
      (Object? data) {
        if (data is! List<int>) return;
        final local = _local;
        if (local == null) {
          early.add(data);
        } else {
          local.add(data);
        }
      },
      onDone: close,
      onError: (Object _) => close(),
    );
    _server.listen((Socket socket) {
      if (_local != null || _closed) {
        socket.destroy();
        return;
      }
      _local = socket;
      try {
        socket.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      early
        ..forEach(socket.add)
        ..clear();
      socket.listen(
        (data) {
          if (!_closed) _relay.add(data);
        },
        onDone: close,
        onError: (Object _) => close(),
      );
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _local?.destroy();
    unawaited(_server.close().catchError((Object _) => _server));
    unawaited(_relay.close().catchError((Object _) {}));
  }
}
