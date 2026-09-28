import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:crypto/crypto.dart';

import 'models.dart';
import 'storage.dart';

/// mDNS service type advertised by the PC daemon.
const String kMdnsType = '_ccnotify._tcp';

/// HttpClient that accepts the PC's self-signed certificate only if
/// SHA-256(cert DER) == [fp]. No trusted roots are loaded, so every
/// certificate goes through the pinning callback.
HttpClient pinnedHttpClient(String fp) {
  final expected = fp.toLowerCase();
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
  client.connectionTimeout = const Duration(seconds: 5);
  client.badCertificateCallback = (X509Certificate cert, String host, int port) =>
      sha256.convert(cert.der).toString() == expected;
  return client;
}

/// `wss://<host>:<port>/` (IPv6 hosts are bracketed by [Uri]).
String wssUrl(String host, int port) =>
    Uri(scheme: 'wss', host: host, port: port, path: '/').toString();

int _asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

void _closeQuietly(WebSocket ws) {
  try {
    ws.close().timeout(const Duration(seconds: 2)).then((_) {}, onError: (_) {});
  } catch (_) {}
}

typedef LinkStateCallback = void Function(PcLink link);

/// Called for every new (non-duplicate) event. [live] is true when the event
/// was not part of the replay (its id is greater than `last_id` from hello).
typedef LinkEventCallback = Future<void> Function(PcLink link, CcEvent event, bool live);

/// Called for every `request` frame (live, and re-sent on every (re)connect —
/// the receiver dedupes by request id).
typedef LinkRequestCallback = Future<void> Function(PcLink link, CcRequest request);

/// Called for every `resolved` frame; [by] is `phone`, `pc` or `timeout`.
typedef LinkResolvedCallback = Future<void> Function(PcLink link, String requestId, String by);

/// Called once per connection when the (re)connect burst is over, with the
/// ids of every request received since `hello` (= all still pending).
typedef LinkRequestsSyncedCallback = Future<void> Function(PcLink link, Set<String> requestIds);

enum _Outcome { failed, helloThenClosed, unauthorized }

/// One long-lived subscription to one PC (PROTOCOL.md "Subscribe").
///
/// Owned by the foreground-task isolate. Writes `since_<pcId>` and
/// `hosts_<pcId>`; never touches `pcs` / `settings`.
class PcLink {
  PcLink({
    required this.pc,
    required this.onState,
    required this.onEvent,
    required this.onRequest,
    required this.onResolved,
    required this.onRequestsSynced,
  });

  final PairedPc pc;
  final LinkStateCallback onState;
  final LinkEventCallback onEvent;
  final LinkRequestCallback onRequest;
  final LinkResolvedCallback onResolved;
  final LinkRequestsSyncedCallback onRequestsSynced;

  static const Duration _minBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 60);
  static const Duration _discoveryTime = Duration(seconds: 5);

  /// After `hello` the PC replays events, then re-sends every pending
  /// request. The burst counts as over after this long without a frame;
  /// listed requests not re-sent by then were resolved while disconnected.
  static const Duration _requestSyncQuiet = Duration(seconds: 5);

  String _state = PcStatus.connecting;
  String get state => _state;

  String? _host;

  /// Host of the current connection, if connected.
  String? get host => _host;

  bool _stopped = false;
  bool _running = false;
  WebSocket? _ws;
  HttpClient? _client;
  Completer<void>? _wake;
  Duration _backoff = _minBackoff;
  int _failStreak = 0;
  final Random _rand = Random();

  void start() {
    if (_running || _stopped) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> stop() async {
    _stopped = true;
    _wakeUp();
    final ws = _ws;
    _ws = null;
    if (ws != null) _closeQuietly(ws);
    _client?.close(force: true);
    _client = null;
  }

  /// Skips the current backoff wait and reconnects right away
  /// (network change / app resume).
  void kick() {
    if (_stopped) return;
    _backoff = _minBackoff;
    _wakeUp();
  }

  void _wakeUp() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// Sends an `answer` frame. Returns false if not connected (the PC re-sends
  /// the request on reconnect; the caller answers again then).
  bool sendAnswer(String requestId, Map<String, dynamic> answer) {
    final ws = _ws;
    if (ws == null || _state != PcStatus.connected) return false;
    try {
      ws.add(jsonEncode({'type': 'answer', 'request_id': requestId, 'answer': answer}));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setState(String s) {
    if (_state == s) return;
    _state = s;
    try {
      onState(this);
    } catch (_) {}
  }

  Future<void> _loop() async {
    while (!_stopped) {
      _setState(PcStatus.connecting);
      final hosts = await _hosts();
      var gotHello = false;
      var unauthorized = false;
      for (final h in hosts) {
        if (_stopped) break;
        final r = await _session(h);
        if (r == _Outcome.unauthorized) {
          unauthorized = true;
          break;
        }
        if (r == _Outcome.helloThenClosed) {
          gotHello = true;
          break;
        }
      }
      if (_stopped) break;
      if (unauthorized) {
        // Device was revoked on the PC: stop retrying until re-paired.
        _setState(PcStatus.unpaired);
        _running = false;
        return;
      }
      if (gotHello) {
        _failStreak = 0;
      } else {
        _failStreak++;
        // All stored hosts failed 3 times in a row → browse mDNS.
        if (_failStreak % 3 == 0) {
          final found = await _discover();
          if (_stopped) break;
          if (found != null && found.isNotEmpty) {
            try {
              await Store.saveHosts(pc.id, found);
            } catch (_) {}
            if (!_sameList(found, hosts)) {
              continue; // retry immediately with the new address
            }
          }
        }
      }
      _setState(PcStatus.offline);
      await _sleep(_jitter(_backoff));
      final next = _backoff * 2;
      _backoff = next > _maxBackoff ? _maxBackoff : next;
    }
    _running = false;
  }

  Future<List<String>> _hosts() async {
    try {
      final h = await Store.loadHosts(pc.id);
      if (h != null && h.isNotEmpty) return h;
    } catch (_) {}
    return pc.hosts;
  }

  Future<int> _loadSince() async {
    try {
      final s = await Store.loadSince(pc.id);
      if (s != null) return s;
    } catch (_) {}
    return pc.initialSince;
  }

  Future<void> _saveSince(int since) async {
    if (_stopped) return;
    try {
      await Store.saveSince(pc.id, since);
    } catch (_) {}
  }

  /// One connection attempt to [host]; returns when the socket closes.
  Future<_Outcome> _session(String host) async {
    final client = pinnedHttpClient(pc.fp);
    _client = client;
    WebSocket ws;
    try {
      ws = await WebSocket.connect(wssUrl(host, pc.port), customClient: client)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
      return _Outcome.failed;
    }
    if (_stopped) {
      _closeQuietly(ws);
      client.close(force: true);
      return _Outcome.failed;
    }
    _ws = ws;
    ws.pingInterval = const Duration(seconds: 25);

    var since = await _loadSince();
    var helloLastId = 0;
    var gotHello = false;
    var unauthorized = false;
    final helloTimer = Timer(const Duration(seconds: 10), () {
      if (!gotHello) _closeQuietly(ws);
    });
    // Request ids seen since hello, until the sync timer fires.
    Set<String>? syncIds;
    Timer? syncTimer;
    void armSyncTimer() {
      syncTimer?.cancel();
      syncTimer = Timer(_requestSyncQuiet, () {
        final ids = syncIds;
        syncIds = null;
        if (ids == null || _stopped || !identical(_ws, ws)) return;
        unawaited(onRequestsSynced(this, ids).catchError((Object _) {}));
      });
    }

    try {
      ws.add(jsonEncode({'type': 'auth', 'token': pc.token, 'since': since}));
      await for (final data in ws) {
        if (_stopped) break;
        if (data is! String) continue;
        Map<String, dynamic> msg;
        try {
          final d = jsonDecode(data);
          if (d is! Map) continue;
          msg = Map<String, dynamic>.from(d);
        } catch (_) {
          continue;
        }
        final type = msg['type'];
        if (syncIds != null) armSyncTimer(); // still in the reconnect burst
        if (type == 'hello') {
          gotHello = true;
          helloTimer.cancel();
          helloLastId = _asInt(msg['last_id']);
          if (since > helloLastId) {
            // PC state was reset.
            since = helloLastId;
            await _saveSince(since);
          }
          _backoff = _minBackoff;
          _failStreak = 0;
          _host = host;
          syncIds = <String>{};
          armSyncTimer();
          _setState(PcStatus.connected);
        } else if (type == 'request') {
          final r = msg['request'];
          if (r is! Map) continue;
          final req = CcRequest.fromJson(Map<String, dynamic>.from(r));
          if (req.id.isEmpty) continue;
          syncIds?.add(req.id);
          try {
            await onRequest(this, req);
          } catch (_) {}
        } else if (type == 'resolved') {
          final id = msg['request_id'];
          if (id is! String || id.isEmpty) continue;
          final by = msg['by'];
          try {
            await onResolved(this, id, by is String ? by : '');
          } catch (_) {}
        } else if (type == 'event') {
          final e = msg['event'];
          if (e is! Map) continue;
          final ev = CcEvent.fromJson(Map<String, dynamic>.from(e));
          if (ev.id <= since) continue; // dedupe
          final live = gotHello && ev.id > helloLastId;
          try {
            await onEvent(this, ev, live);
          } catch (_) {}
          since = ev.id;
          await _saveSince(since);
        } else if (type == 'error') {
          if (msg['error'] == 'unauthorized') unauthorized = true;
        }
      }
    } catch (_) {
      // Socket error: treated as a closed connection.
    } finally {
      helloTimer.cancel();
      syncTimer?.cancel();
      if (identical(_ws, ws)) _ws = null;
      _host = null;
      _closeQuietly(ws);
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
    if (unauthorized) return _Outcome.unauthorized;
    return gotHello ? _Outcome.helloThenClosed : _Outcome.failed;
  }

  Future<void> _sleep(Duration d) async {
    final c = Completer<void>();
    _wake = c;
    final t = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    await c.future;
    t.cancel();
    if (identical(_wake, c)) _wake = null;
  }

  Duration _jitter(Duration d) {
    final factor = 0.8 + _rand.nextDouble() * 0.4; // ±20 %
    return Duration(milliseconds: (d.inMilliseconds * factor).round());
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Browses `_ccnotify._tcp` for ~5 s and returns the addresses of the
  /// service whose TXT `id` equals this PC's id (IPv4 preferred).
  Future<List<String>?> _discover() async {
    BonsoirDiscovery? discovery;
    StreamSubscription<BonsoirDiscoveryEvent>? sub;
    final result = Completer<List<String>?>();
    try {
      final d = BonsoirDiscovery(type: kMdnsType, printLogs: false);
      discovery = d;
      await d.initialize();
      sub = d.eventStream?.listen((BonsoirDiscoveryEvent event) {
        final svc = event.service;
        if (svc == null || result.isCompleted) return;
        final id = svc.attributes['id'];
        if (id != null && id != pc.id) return;
        if (id == pc.id && svc.hostAddresses.isNotEmpty) {
          final addrs = pickAddresses(svc.hostAddresses);
          if (addrs.isNotEmpty) result.complete(addrs);
          return;
        }
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          // TXT / addresses become available after resolution.
          unawaited(svc.resolve(d.serviceResolver).catchError((Object _) {}));
        }
      });
      await d.start();
      return await result.future.timeout(_discoveryTime, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        await discovery?.stop();
      } catch (_) {}
    }
  }
}

/// Keeps usable addresses: IPv4 first; routable IPv6 only if no IPv4.
List<String> pickAddresses(List<String> addrs) {
  final v4 = <String>[];
  final v6 = <String>[];
  for (final a in addrs) {
    final ip = InternetAddress.tryParse(a.split('%').first);
    if (ip == null || ip.isLoopback) continue;
    if (ip.type == InternetAddressType.IPv4) {
      if (!v4.contains(ip.address)) v4.add(ip.address);
    } else if (ip.type == InternetAddressType.IPv6 && !ip.isLinkLocal) {
      if (!v6.contains(ip.address)) v6.add(ip.address);
    }
  }
  return v4.isNotEmpty ? v4 : v6;
}
