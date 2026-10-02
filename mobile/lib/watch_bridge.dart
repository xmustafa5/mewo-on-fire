import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'models.dart';

/// The Apple Watch app (ios/CcnotifyWatch). A watch cannot keep a connection
/// to a PC of its own, so it goes through this app: the native side
/// (ios/Runner/WatchBridge.swift) hands the watch's commands to [_onCall] and
/// gets the list of waiting prompts and sessions pushed whenever it changes.
///
/// Everything crosses as UTF-8 JSON. Commands (`cmd`):
/// - `state` → `{"state": <snapshot>}`
/// - `chat` `{pcId, sessionId, before?, have?}` → a page of the chat, newest last
/// - `send` `{pcId, sessionId, text}` → `{"status", "reason"}`
/// - `answer` `{pcId, requestId, answer}` → `{"resolved": bool}`
/// A failed command answers `{"error": "<text for the watch>"}`.
class WatchBridge {
  WatchBridge._();
  static final WatchBridge instance = WatchBridge._();

  static const MethodChannel _channel = MethodChannel('ccnotify/watch');

  final AppState _state = AppState.instance;
  Timer? _pushTimer;
  String _pushed = '';

  /// Wall clock of the last [_tick]: a gap means iOS had the app suspended,
  /// and its connections may be dead without anyone having noticed yet.
  DateTime _lastTick = DateTime.now();
  DateTime _resumedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _tickEvery = Duration(seconds: 4);
  static const Duration _suspendedGap = Duration(seconds: 12);

  void init() {
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler(_onCall);
    _state.addListener(_schedulePush);
    Timer.periodic(_tickEvery, (_) => _tick());
    _schedulePush();
  }

  void _tick() {
    final now = DateTime.now();
    if (now.difference(_lastTick) > _suspendedGap) _resumedAt = now;
    _lastTick = now;
  }

  bool get _justResumed {
    final now = DateTime.now();
    return now.difference(_lastTick) > _suspendedGap ||
        now.difference(_resumedAt) < const Duration(seconds: 3);
  }

  // ---- phone → watch ----

  void _schedulePush() {
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 400), _push);
  }

  Future<void> _push() async {
    if (!_state.loaded) return;
    final json = jsonEncode(watchSnapshot(_state));
    if (json == _pushed) return;
    try {
      await _channel.invokeMethod<void>('context', Uint8List.fromList(utf8.encode(json)));
      _pushed = json;
    } catch (e) {
      debugPrint('ccnotify: watch push failed: $e');
    }
  }

  // ---- watch → phone ----

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'command') throw MissingPluginException();
    var q = <String, dynamic>{};
    try {
      final d = jsonDecode(utf8.decode(call.arguments as Uint8List));
      if (d is Map) q = Map<String, dynamic>.from(d);
    } catch (_) {}
    Map<String, dynamic> reply;
    try {
      reply = await _run(q);
    } catch (e) {
      debugPrint('ccnotify: watch command failed: $e');
      reply = {'error': 'The iPhone app could not do that'};
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(reply)));
  }

  static String _str(Object? v) => v is String ? v : '';

  Future<Map<String, dynamic>> _run(Map<String, dynamic> q) async {
    await _until(() => _state.loaded, const Duration(seconds: 5));
    if (_state.pcs.isEmpty) {
      return {'error': 'Pair a PC in ccnotify on the iPhone first'};
    }
    final pcId = _str(q['pcId']);
    switch (_str(q['cmd'])) {
      case 'state':
        await _connect(null);
        return {'state': watchSnapshot(_state)};
      case 'chat':
        return _chat(pcId, _str(q['sessionId']),
            before: q['before'] is String ? q['before'] as String : null, have: _str(q['have']));
      case 'send':
        final text = _str(q['text']).trim();
        if (text.isEmpty) return {'error': 'Nothing to send'};
        await _connect(pcId);
        final m = await _state.sendMessage(pcId, _str(q['sessionId']), text);
        if (m == null) return {'error': 'Nothing to send'};
        await _until(() => m.status != SendStatus.sending, const Duration(seconds: 8));
        return {'status': m.status, 'reason': m.reason};
      case 'answer':
        final requestId = _str(q['requestId']);
        final answer = q['answer'];
        if (answer is! Map) return {'error': 'No answer given'};
        if (_state.findRequest(pcId, requestId) == null) {
          return {'error': 'Claude is no longer waiting for this'};
        }
        await _connect(pcId);
        await _state.answer(pcId, requestId, Map<String, dynamic>.from(answer));
        final resolved = await _until(
            () => _state.findRequest(pcId, requestId) == null, const Duration(seconds: 5));
        return {'resolved': resolved};
      default:
        return {'error': 'Update ccnotify on the iPhone'};
    }
  }

  /// [before]: id of the oldest line the watch shows, for the page above it.
  /// [have]: the `sig` of the newest page the watch already shows; answered
  /// with `{"same": true}` when nothing changed since (the watch polls).
  Future<Map<String, dynamic>> _chat(
    String pcId,
    String sessionId, {
    String? before,
    String have = '',
  }) async {
    var chat = _state.chatOf(pcId, sessionId);
    // Older pages come from the chat as last fetched; the newest one is
    // fetched again.
    if (before == null || chat == null || !chat.loaded) {
      await _connect(pcId);
      await _state.refreshChat(pcId, sessionId);
      chat = _state.chatOf(pcId, sessionId);
    }
    if (chat == null || !chat.loaded) {
      return {'error': chat != null && chat.error.isNotEmpty ? chat.error : 'Could not load the chat'};
    }
    final items = chat.items;
    final page = watchChatPage(items, before: before);
    if (before != null) return {...page, 'warning': chat.error};

    // Sent from this phone (or the watch) and not in the chat yet.
    final waiting = [
      for (final m in _state.outgoingOf(pcId, sessionId))
        if (!items.any((it) =>
            it.role == ChatRole.phone &&
            (it.id == 'phone-${m.clientId}' ||
                (it.text.trim() == m.text && it.ts >= m.ts - 10 * 60 * 1000))))
          m,
    ];
    final last = items.isEmpty ? null : items.last;
    final sig = '${items.length}:${last?.ts ?? 0}:${last?.text.length ?? 0}:'
        '${waiting.map((m) => '${m.clientId}=${m.status}').join(',')}';
    if (sig == have) return {'same': true, 'warning': chat.error};
    final lines = page['items'] as List<Map<String, dynamic>>;
    for (final m in waiting) {
      lines.add({
        'id': 'out-${m.clientId}',
        'role': ChatRole.phone,
        'text': m.text,
        'ts': m.ts,
        'status': switch (m.status) {
          SendStatus.sending => 'Sending…',
          SendStatus.queued => 'Queued',
          SendStatus.rejected => m.reason.isEmpty ? 'Not sent' : 'Not sent: ${m.reason}',
          _ => '',
        },
      });
    }
    return {...page, 'sig': sig, 'warning': chat.error};
  }

  /// Makes sure [pcId] (every PC when null) is connected before a command
  /// uses it, for a few seconds at most: woken up by the watch, the app may
  /// have been suspended for hours.
  Future<void> _connect(String? pcId) async {
    bool connected() => pcId == null
        ? _state.pcs.every((p) => _state.statusOf(p.id) == PcStatus.connected)
        : _state.statusOf(pcId) == PcStatus.connected;
    if (_justResumed) {
      // "Connected" is from before the suspension: let the probe find out.
      await _state.wake();
      await Future<void>.delayed(const Duration(milliseconds: 2500));
    } else if (connected()) {
      return;
    } else {
      await _state.wake();
    }
    await _until(connected, const Duration(seconds: 6));
  }

  /// Completes with true once [test] holds (checked whenever the app state
  /// changes), or with false after [max].
  Future<bool> _until(bool Function() test, Duration max) {
    if (test()) return Future<bool>.value(true);
    final c = Completer<bool>();
    void check() {
      if (!c.isCompleted && test()) c.complete(true);
    }

    _state.addListener(check);
    final timer = Timer(max, () {
      if (!c.isCompleted) c.complete(test());
    });
    return c.future.whenComplete(() {
      _state.removeListener(check);
      timer.cancel();
    });
  }
}

/// A watch message carries a few tens of kilobytes at most.
const int kWatchPageBytes = 40000;
const int _maxWatchSessions = 30;
const int _maxWatchRequests = 12;

String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

/// [s] cut to [maxBytes] of UTF-8.
String _clipBytes(String s, int maxBytes) {
  if (utf8.encode(s).length <= maxBytes) return s;
  var cut = s.length;
  while (cut > 0 && utf8.encode(s.substring(0, cut)).length > maxBytes) {
    cut = cut * 3 ~/ 4;
  }
  // Not in the middle of a surrogate pair.
  if (cut > 0 && (s.codeUnitAt(cut - 1) & 0xFC00) == 0xD800) cut--;
  return '${s.substring(0, cut)}\n… (the rest is on the iPhone)';
}

/// What the watch lists: PCs, waiting prompts and sessions, newest first.
Map<String, dynamic> watchSnapshot(AppState s) => {
      'running': s.serviceRunning,
      'pcs': [
        for (final p in s.pcs) {'id': p.id, 'name': p.name, 'status': s.statusOf(p.id)},
      ],
      'requests': [
        for (final r in s.requests.take(_maxWatchRequests))
          {
            'pcId': r.pcId,
            'pcName': r.pcName,
            'id': r.request.id,
            'ts': r.request.ts,
            'kind': r.request.kind,
            'project': r.request.project,
            'session': r.request.session,
            'tool': r.request.tool,
            'title': _clip(r.request.title, 200),
            'detail': _clip(
                r.request.detail.isNotEmpty ? r.request.detail : r.request.summary, 1500),
            'always': r.request.canAllowAlways,
            'answered': r.answered,
            'questions': [
              for (final q in r.request.questions)
                {
                  'question': _clip(q.question, 400),
                  // Answers are keyed by the whole question text.
                  'key': q.question,
                  'header': q.header,
                  'multi': q.multiSelect,
                  'options': [
                    for (final o in q.options)
                      {'label': o.label, 'description': _clip(o.description, 200)},
                  ],
                },
            ],
          },
      ],
      'sessions': [
        for (final e in s.sessions.take(_maxWatchSessions))
          {
            'pcId': e.pcId,
            'pcName': e.pcName,
            'id': e.session.id,
            'short': e.session.short,
            'title': _clip(e.session.displayTitle, 80),
            'project': e.session.project,
            'state': e.session.state,
            'listening': e.session.listening,
            'readOnly': e.session.readOnly,
            'lastTs': e.session.lastTs,
            'lastText': _clip(e.session.lastText, 120),
            'queued': e.session.queued,
          },
      ],
    };

/// The chat items above the line with id [before] (the newest ones when
/// null) that fit one watch message, oldest first. A run of tool calls
/// becomes one line, named `t:<id of its first call>`. `more`: there are
/// older items above this page.
Map<String, dynamic> watchChatPage(
  List<ChatItem> items, {
  String? before,
  int budget = kWatchPageBytes,
}) {
  var end = items.length;
  if (before != null) {
    final id = before.startsWith('t:') ? before.substring(2) : before;
    // Not there any more (the PC only keeps the newest items): nothing above.
    end = items.indexWhere((it) => it.id == id);
    if (end < 0) end = 0;
  }
  final out = <Map<String, dynamic>>[]; // newest first
  var used = 0;
  var i = end;
  while (i > 0) {
    var start = i - 1;
    String text;
    final role = items[start].role;
    if (role == ChatRole.tool) {
      while (start > 0 && items[start - 1].role == ChatRole.tool) {
        start--;
      }
      text = _toolLine(items.sublist(start, i));
    } else {
      text = items[start].text;
      if (text.trim().isEmpty && items[start].images.isNotEmpty) text = '[image]';
    }
    var size = utf8.encode(text).length + 120;
    if (size > budget) {
      text = _clipBytes(text, budget - 240);
      size = budget;
    }
    if (out.isNotEmpty && used + size > budget) break;
    out.add({
      'id': role == ChatRole.tool ? 't:${items[start].id}' : items[start].id,
      'role': role,
      'text': text,
      'ts': items[start].ts,
      'status': '',
    });
    used += size;
    i = start;
  }
  return {'more': i > 0, 'items': out.reversed.toList()};
}

/// "Bash: cargo test", or "5 tool calls: Bash, Read, Edit".
String _toolLine(List<ChatItem> tools) {
  if (tools.length == 1) {
    final t = tools.first;
    final line = t.text.split('\n').first.trim();
    if (t.tool.isEmpty) return _clip(line, 100);
    return line.isEmpty ? t.tool : '${t.tool}: ${_clip(line, 100)}';
  }
  final names = <String>[];
  for (final t in tools) {
    if (t.tool.isNotEmpty && !names.contains(t.tool)) names.add(t.tool);
  }
  final shown = names.take(4).join(', ');
  return '${tools.length} tool calls${shown.isEmpty ? '' : ': $shown'}${names.length > 4 ? '…' : ''}';
}
