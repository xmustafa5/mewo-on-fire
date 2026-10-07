import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:crypto/crypto.dart';

import 'models.dart';
import 'relay_tunnel.dart';
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

/// Called for the `sessions` reply (all sessions of the PC, newest first).
typedef LinkSessionsCallback = Future<void> Function(PcLink link, List<CcSession> sessions);

/// Called for every live `session` update.
typedef LinkSessionCallback = Future<void> Function(PcLink link, CcSession session);

/// Called for every `chat` reply (the raw frame: `session_id`, `title`, `items`).
typedef LinkChatCallback = Future<void> Function(PcLink link, Map<String, dynamic> chat);

/// Called for every `image` reply (the raw frame: `session_id`, `image_id`,
/// then `mime` + `data`, or `error`).
typedef LinkImageCallback = Future<void> Function(PcLink link, Map<String, dynamic> image);

/// Called for every `send_result`; [status] is `delivered`, `queued` or `rejected`.
/// `prs` (v1.6): the open pull requests of a session's repository.
typedef LinkPrsCallback = Future<void> Function(PcLink link, Map<String, dynamic> prs);

typedef LinkSendResultCallback = Future<void> Function(
    PcLink link, String clientId, String status, String reason);

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
    required this.onSessions,
    required this.onSession,
    required this.onChat,
    required this.onImage,
    required this.onSendResult,
    required this.onPrs,
  });

  final PairedPc pc;
  final LinkStateCallback onState;
  final LinkEventCallback onEvent;
  final LinkRequestCallback onRequest;
  final LinkResolvedCallback onResolved;
  final LinkRequestsSyncedCallback onRequestsSynced;
  final LinkSessionsCallback onSessions;
  final LinkSessionCallback onSession;
  final LinkChatCallback onChat;
  final LinkImageCallback onImage;
  final LinkSendResultCallback onSendResult;
  final LinkPrsCallback onPrs;

  static const Duration _minBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 60);
  static const Duration _discoveryTime = Duration(seconds: 5);
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _lanConnectTimeout = Duration(seconds: 4);

  /// After `hello` the PC replays events, then re-sends every pending
  /// request. The burst counts as over after this long without a frame;
  /// listed requests not re-sent by then were resolved while disconnected.
  static const Duration _requestSyncQuiet = Duration(seconds: 5);

  /// WebSocket ping interval. dart:io closes the socket when a pong does not
  /// arrive within the same interval.
  static const Duration _pingInterval = Duration(seconds: 25);

  /// Ping interval while [probe] checks the connection.
  static const Duration _probeInterval = Duration(seconds: 2);

  String _state = PcStatus.connecting;
  String get state => _state;

  String? _host;

  /// The address of the last connection that got as far as hello.
  String? _lastGoodHost;

  /// Host of the current connection, if connected.
  String? get host => _host;

  bool _stopped = false;
  bool _running = false;
  WebSocket? _ws;
  HttpClient? _client;
  Completer<void>? _wake;
  Duration _backoff = _minBackoff;
  int _failStreak = 0;
  Timer? _probeTimer;
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

  /// Checks that a `connected` link is still alive: the socket can die
  /// unnoticed while the app is suspended (iOS) or the phone dozes. Pings
  /// right away instead of at the next regular ping; without a pong the
  /// socket is closed and the loop reconnects.
  void probe() {
    final ws = _ws;
    if (_stopped || ws == null || _state != PcStatus.connected) return;
    ws.pingInterval = _probeInterval;
    _probeTimer?.cancel();
    _probeTimer = Timer(_probeInterval * 3, () {
      if (identical(_ws, ws)) ws.pingInterval = _pingInterval;
    });
  }

  /// The phone moved to another network while this link was connected.
  /// - Connected through a relay or VPN address: maybe this is the PC's own
  ///   network now, so reconnect, LAN address first.
  /// - Connected on the LAN: the connection may be dead without anyone having
  ///   noticed; find out now rather than at the next regular ping.
  void networkChanged() {
    if (_stopped || _state != PcStatus.connected) return;
    final host = _host;
    if (host == null || isLanHost(host)) {
      probe();
      return;
    }
    _lastGoodHost = null;
    _backoff = _minBackoff;
    final ws = _ws;
    if (ws != null) _closeQuietly(ws);
  }

  void _wakeUp() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// Sends an `answer` frame. Returns false if not connected (the PC re-sends
  /// the request on reconnect; the caller answers again then).
  bool sendAnswer(String requestId, Map<String, dynamic> answer) =>
      _sendFrame({'type': 'answer', 'request_id': requestId, 'answer': answer});

  /// Asks for all sessions (reply → [onSessions]). False if not connected.
  bool requestSessions() => _sendFrame({'type': 'sessions'});

  /// v1.6: the pull requests of the session's repository → `prs`.
  bool getPrs(String sessionId) => _sendFrame({'type': 'get_prs', 'session_id': sessionId});

  /// Asks for a session's chat (reply → [onChat]). False if not connected.
  bool getChat(String sessionId, {int limit = 100}) =>
      _sendFrame({'type': 'get_chat', 'session_id': sessionId, 'limit': limit});

  /// Asks for an image of a session's chat (reply → [onImage]). False if not connected.
  bool getImage(String sessionId, String imageId) =>
      _sendFrame({'type': 'get_image', 'session_id': sessionId, 'image_id': imageId});

  /// Sends a message to a session (reply → [onSendResult]). False if not
  /// connected. [images]: `{"mime", "data": <base64>}` each (v1.3).
  bool sendMessage(
    String sessionId,
    String text,
    String clientId, {
    List<Object?> images = const <Object?>[],
  }) =>
      _sendFrame({
        'type': 'send',
        'session_id': sessionId,
        'text': text,
        'client_id': clientId,
        if (images.isNotEmpty) 'images': images,
      });

  bool _sendFrame(Map<String, dynamic> frame) {
    final ws = _ws;
    if (ws == null || _state != PcStatus.connected) return false;
    try {
      ws.add(jsonEncode(frame));
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
      final stored = await _hosts();
      // The address that worked last first: away from home that is the
      // remote one, and the LAN address would only cost a timeout.
      final hosts = orderHosts(stored, _lastGoodHost);
      var gotHello = false;
      var unauthorized = false;
      for (final h in hosts) {
        if (_stopped) break;
        // An address on the LAN answers at once or not at all.
        final r = await _session(
          h,
          connectTimeout: hosts.length > 1 && isLanHost(h) ? _lanConnectTimeout : _connectTimeout,
        );
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
            // The PC's new LAN address; its remote addresses stay.
            final merged = mergeDiscovered(found, stored);
            try {
              await Store.saveHosts(pc.id, merged);
            } catch (_) {}
            if (!_sameList(merged, stored)) {
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

  /// One connection attempt to [host] — an address, or a relay
  /// (`wss://…`) that leads to the PC; returns when the socket closes.
  Future<_Outcome> _session(String host, {Duration connectTimeout = _connectTimeout}) async {
    if (!RelayTunnel.isRelay(host)) {
      return _sessionAt(host, pc.port, host, connectTimeout);
    }
    final RelayTunnel tunnel;
    try {
      tunnel = await RelayTunnel.open(host, pc.id, timeout: connectTimeout);
    } catch (_) {
      return _Outcome.failed; // relay unreachable, or the PC is not on it
    }
    try {
      return await _sessionAt('127.0.0.1', tunnel.port, host, connectTimeout);
    } finally {
      tunnel.close();
    }
  }

  /// The session with whatever answers at [address]:[port]; [host] is what
  /// it is remembered by.
  Future<_Outcome> _sessionAt(
    String address,
    int port,
    String host,
    Duration connectTimeout,
  ) async {
    final client = pinnedHttpClient(pc.fp);
    _client = client;
    WebSocket ws;
    try {
      ws = await WebSocket.connect(wssUrl(address, port), customClient: client)
          .timeout(connectTimeout);
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
    ws.pingInterval = _pingInterval;

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
          _lastGoodHost = host;
          // v1.4: where the PC can be reached now (LAN, then remote).
          final reported = <String>[
            if (msg['hosts'] is List)
              for (final h in msg['hosts'] as List)
                if (h is String && h.isNotEmpty) h,
          ];
          if (reported.isNotEmpty && !_sameList(reported, await _hosts())) {
            try {
              await Store.saveHosts(pc.id, reported);
            } catch (_) {}
          }
          syncIds = <String>{};
          armSyncTimer();
          _setState(PcStatus.connected);
          requestSessions(); // v1.2; older daemons ignore it
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
        } else if (type == 'sessions') {
          final list = msg['sessions'];
          if (list is! List) continue;
          final sessions = <CcSession>[];
          for (final e in list) {
            if (e is! Map) continue;
            final s = CcSession.fromJson(Map<String, dynamic>.from(e));
            if (s.id.isNotEmpty) sessions.add(s);
          }
          try {
            await onSessions(this, sessions);
          } catch (_) {}
        } else if (type == 'session') {
          final e = msg['session'];
          if (e is! Map) continue;
          final s = CcSession.fromJson(Map<String, dynamic>.from(e));
          if (s.id.isEmpty) continue;
          try {
            await onSession(this, s);
          } catch (_) {}
        } else if (type == 'chat') {
          final id = msg['session_id'];
          if (id is! String || id.isEmpty) continue;
          try {
            await onChat(this, msg);
          } catch (_) {}
        } else if (type == 'prs') {
          final id = msg['session_id'];
          if (id is! String || id.isEmpty) continue;
          try {
            await onPrs(this, msg);
          } catch (_) {}
        } else if (type == 'image') {
          final id = msg['image_id'];
          if (id is! String || id.isEmpty) continue;
          try {
            await onImage(this, msg);
          } catch (_) {}
        } else if (type == 'send_result') {
          final id = msg['client_id'];
          if (id is! String || id.isEmpty) continue;
          final status = msg['status'];
          final reason = msg['reason'];
          try {
            await onSendResult(
                this, id, status is String ? status : '', reason is String ? reason : '');
          } catch (_) {}
        } else if (type == 'error') {
          if (msg['error'] == 'unauthorized') unauthorized = true;
        }
      }
    } catch (_) {
      // Socket error: treated as a closed connection.
    } finally {
      helloTimer.cancel();
      syncTimer?.cancel();
      _probeTimer?.cancel();
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

/// Whether [host] is an address of a home or office network — as opposed to
/// a VPN address (Tailscale) or a name, which also work from elsewhere.
bool isLanHost(String host) {
  final ip = InternetAddress.tryParse(host);
  if (ip == null) return false;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }
  return ip.isLinkLocal || (b[0] & 0xFE) == 0xFC; // fe80::/10, fc00::/7
}

/// [hosts] in the order to try them: [lastGood] first when it is one of them.
List<String> orderHosts(List<String> hosts, String? lastGood) {
  if (lastGood == null || !hosts.contains(lastGood)) return hosts;
  return <String>[lastGood, ...hosts.where((h) => h != lastGood)];
}

/// What to remember once mDNS found the PC at [found]: those addresses, then
/// the remote ones among [known] (mDNS only sees the LAN).
List<String> mergeDiscovered(List<String> found, List<String> known) => <String>[
      ...found,
      ...known.where((h) => !isLanHost(h) && !found.contains(h)),
    ];

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
