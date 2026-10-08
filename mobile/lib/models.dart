import 'dart:convert';

/// Event kinds defined by PROTOCOL.md.
class EventKind {
  static const stop = 'stop';
  static const needsInput = 'needs_input';
  static const sessionEnd = 'session_end';
}

int _asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String _asString(Object? v) => v is String ? v : (v == null ? '' : '$v');

List<String> _asStringList(Object? v) =>
    v is List ? v.map((e) => '$e').where((e) => e.isNotEmpty).toList() : <String>[];

/// Connection state of one PC link, as shown in the UI.
class PcStatus {
  static const connected = 'connected';
  static const connecting = 'connecting';
  static const offline = 'offline';
  static const unpaired = 'unpaired';
}

/// A Claude Code event emitted by the PC daemon.
class CcEvent {
  const CcEvent({
    required this.id,
    required this.ts,
    required this.kind,
    required this.project,
    this.cwd = '',
    this.session = '',
    this.message = '',
    this.detail = '',
    this.sessionId = '',
  });

  final int id;
  final int ts; // unix ms
  final String kind;
  final String project;
  final String cwd;
  final String session;
  final String message;
  final String detail;

  /// Full Claude Code session id (v1.2; empty for events of older daemons).
  final String sessionId;

  factory CcEvent.fromJson(Map<String, dynamic> j) => CcEvent(
        id: _asInt(j['id']),
        ts: _asInt(j['ts']),
        kind: _asString(j['kind']),
        project: _asString(j['project']),
        cwd: _asString(j['cwd']),
        session: _asString(j['session']),
        message: _asString(j['message']),
        detail: _asString(j['detail']),
        sessionId: _asString(j['session_id']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': ts,
        'kind': kind,
        'project': project,
        'cwd': cwd,
        'session': session,
        'message': message,
        'detail': detail,
        if (sessionId.isNotEmpty) 'session_id': sessionId,
      };

  /// Text shown as notification body / history line.
  String get text => message.isNotEmpty ? message : detail;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);
}

/// One row of the local history (`events` pref): an event plus which PC sent it.
class HistoryEntry {
  const HistoryEntry({required this.pcId, required this.pcName, required this.event});

  final String pcId;
  final String pcName;
  final CcEvent event;

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        pcId: _asString(j['pc_id']),
        pcName: _asString(j['pc_name']),
        event: CcEvent.fromJson(Map<String, dynamic>.from(j['event'] as Map)),
      );

  Map<String, dynamic> toJson() => {
        'pc_id': pcId,
        'pc_name': pcName,
        'event': event.toJson(),
      };
}

/// A PC this phone is paired with (`pcs` pref, written only by the UI isolate).
class PairedPc {
  const PairedPc({
    required this.id,
    required this.name,
    required this.hosts,
    required this.port,
    required this.fp,
    required this.token,
    required this.deviceId,
    required this.initialSince,
  });

  final String id;
  final String name;
  final List<String> hosts;
  final int port;
  final String fp;
  final String token;
  final String deviceId;
  final int initialSince;

  factory PairedPc.fromJson(Map<String, dynamic> j) => PairedPc(
        id: _asString(j['id']),
        name: _asString(j['name']),
        hosts: _asStringList(j['hosts']),
        port: _asInt(j['port']),
        fp: _asString(j['fp']).toLowerCase(),
        token: _asString(j['token']),
        deviceId: _asString(j['device_id']),
        initialSince: _asInt(j['initial_since']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hosts': hosts,
        'port': port,
        'fp': fp,
        'token': token,
        'device_id': deviceId,
        'initial_since': initialSince,
      };
}

/// Request kinds defined by PROTOCOL.md v1.1 "Request".
class RequestKind {
  static const permission = 'permission';
  static const question = 'question';
  static const plan = 'plan';
}

/// One option of an `AskUserQuestion` question.
class RequestOption {
  const RequestOption({required this.label, this.description = ''});

  final String label;
  final String description;

  factory RequestOption.fromJson(Object? j) {
    if (j is Map) {
      return RequestOption(label: _asString(j['label']), description: _asString(j['description']));
    }
    return RequestOption(label: _asString(j));
  }

  Map<String, dynamic> toJson() => {'label': label, 'description': description};
}

/// One entry of `tool_input.questions` (kind `question`).
class RequestQuestion {
  const RequestQuestion({
    required this.question,
    this.header = '',
    this.options = const <RequestOption>[],
    this.multiSelect = false,
  });

  final String question;
  final String header;
  final List<RequestOption> options;
  final bool multiSelect;

  factory RequestQuestion.fromJson(Map<String, dynamic> j) => RequestQuestion(
        question: _asString(j['question']),
        header: _asString(j['header']),
        options: j['options'] is List
            ? (j['options'] as List)
                .map(RequestOption.fromJson)
                .where((o) => o.label.isNotEmpty)
                .toList()
            : const <RequestOption>[],
        multiSelect: j['multiSelect'] == true,
      );

  Map<String, dynamic> toJson() => {
        'question': question,
        'header': header,
        'options': options.map((o) => o.toJson()).toList(),
        'multiSelect': multiSelect,
      };
}

/// A prompt Claude Code is waiting on (PROTOCOL.md v1.1 "Request").
class CcRequest {
  const CcRequest({
    required this.id,
    required this.ts,
    required this.kind,
    required this.project,
    this.session = '',
    this.tool = '',
    this.title = '',
    this.summary = '',
    this.detail = '',
    this.canAllowAlways = false,
    this.questions = const <RequestQuestion>[],
  });

  final String id; // 8 hex
  final int ts; // unix ms
  final String kind;
  final String project;
  final String session;
  final String tool;
  final String title;
  final String summary;
  final String detail;
  final bool canAllowAlways;
  final List<RequestQuestion> questions;

  factory CcRequest.fromJson(Map<String, dynamic> j) {
    final qs = <RequestQuestion>[];
    final raw = j['questions'];
    if (raw is List) {
      for (final q in raw) {
        if (q is Map) {
          final parsed = RequestQuestion.fromJson(Map<String, dynamic>.from(q));
          if (parsed.question.isNotEmpty) qs.add(parsed);
        }
      }
    }
    return CcRequest(
      id: _asString(j['id']),
      ts: _asInt(j['ts']),
      kind: _asString(j['kind']),
      project: _asString(j['project']),
      session: _asString(j['session']),
      tool: _asString(j['tool']),
      title: _asString(j['title']),
      summary: _asString(j['summary']),
      detail: _asString(j['detail']),
      canAllowAlways: j['can_allow_always'] == true,
      questions: qs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': ts,
        'kind': kind,
        'project': project,
        'session': session,
        'tool': tool,
        'title': title,
        'summary': summary,
        'detail': detail,
        'can_allow_always': canAllowAlways,
        'questions': questions.map((q) => q.toJson()).toList(),
      };

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);
}

/// Key of a request across PCs (request ids are only unique per PC).
String requestKey(String pcId, String requestId) => '$pcId:$requestId';

/// One row of `pending_requests` (written only by the task isolate): a request
/// plus which PC sent it. [answer] is set once this phone answered it and kept
/// until the PC confirms with `resolved` (re-sent if the PC asks again).
class PendingRequest {
  const PendingRequest({
    required this.pcId,
    required this.pcName,
    required this.request,
    this.answer,
  });

  final String pcId;
  final String pcName;
  final CcRequest request;
  final Map<String, dynamic>? answer;

  bool get answered => answer != null;
  String get key => requestKey(pcId, request.id);

  factory PendingRequest.fromJson(Map<String, dynamic> j) => PendingRequest(
        pcId: _asString(j['pc_id']),
        pcName: _asString(j['pc_name']),
        request: CcRequest.fromJson(Map<String, dynamic>.from(j['request'] as Map)),
        answer: j['answer'] is Map ? Map<String, dynamic>.from(j['answer'] as Map) : null,
      );

  Map<String, dynamic> toJson() => {
        'pc_id': pcId,
        'pc_name': pcName,
        'request': request.toJson(),
        if (answer != null) 'answer': answer,
      };

  PendingRequest withAnswer(Map<String, dynamic> a) =>
      PendingRequest(pcId: pcId, pcName: pcName, request: request, answer: a);
}

/// Session states (PROTOCOL.md v1.2 "Session registry").
class SessionState {
  static const working = 'working';
  static const idle = 'idle';
  static const waiting = 'waiting';
  static const ended = 'ended';
}

/// Something a session published with Claude's Artifact tool (PROTOCOL.md
/// v1.6): a design canvas, a document, a page.
class SessionArtifact {
  const SessionArtifact({required this.url, this.title = '', this.kind = 'artifact', this.ts = 0});

  final String url;
  final String title;

  /// `design`, `document`, `page` or `artifact`.
  final String kind;
  final int ts;

  factory SessionArtifact.fromJson(Map<String, dynamic> j) => SessionArtifact(
        url: _asString(j['url']),
        title: _asString(j['title']),
        kind: _asString(j['kind']).isEmpty ? 'artifact' : _asString(j['kind']),
        ts: _asInt(j['ts']),
      );

  Map<String, dynamic> toJson() => {'url': url, 'title': title, 'kind': kind, 'ts': ts};

  String get kindLabel {
    switch (kind) {
      case 'design':
        return 'Design';
      case 'document':
        return 'Document';
      case 'page':
        return 'Page';
      default:
        return 'Artifact';
    }
  }

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);
}

/// A Claude Code session known to a PC daemon (PROTOCOL.md v1.2).
class CcSession {
  const CcSession({
    required this.id,
    this.short = '',
    this.project = '',
    this.cwd = '',
    this.title = '',
    this.state = SessionState.idle,
    this.listening = false,
    this.readOnly = false,
    this.effort = '',
    this.lastTs = 0,
    this.lastText = '',
    this.queued = 0,
    this.artifacts = const <SessionArtifact>[],
  });

  final String id; // full session id
  final String short;
  final String project;
  final String cwd;
  final String title;
  final String state;
  final bool listening;
  final bool readOnly;
  final String effort;
  final int lastTs; // unix ms
  final String lastText;
  final int queued;

  /// v1.6: designs, documents and pages the session published, oldest first.
  final List<SessionArtifact> artifacts;

  factory CcSession.fromJson(Map<String, dynamic> j) => CcSession(
        id: _asString(j['id']),
        short: _asString(j['short']),
        project: _asString(j['project']),
        cwd: _asString(j['cwd']),
        title: _asString(j['title']),
        state: _asString(j['state']),
        listening: j['listening'] == true,
        readOnly: j['read_only'] == true,
        effort: _asString(j['effort']),
        lastTs: _asInt(j['last_ts']),
        lastText: _asString(j['last_text']),
        queued: _asInt(j['queued']),
        artifacts: <SessionArtifact>[
          if (j['artifacts'] is List)
            for (final a in j['artifacts'] as List)
              if (a is Map) SessionArtifact.fromJson(Map<String, dynamic>.from(a)),
        ],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'short': short,
        'project': project,
        'cwd': cwd,
        'title': title,
        'state': state,
        'listening': listening,
        'read_only': readOnly,
        'effort': effort,
        'last_ts': lastTs,
        'last_text': lastText,
        'queued': queued,
        if (artifacts.isNotEmpty) 'artifacts': artifacts.map((a) => a.toJson()).toList(),
      };

  bool get ended => state == SessionState.ended;

  String get displayTitle {
    if (title.isNotEmpty) return title;
    if (project.isNotEmpty) return project;
    if (short.isNotEmpty) return short;
    return id.length > 8 ? id.substring(0, 8) : id;
  }

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(lastTs);
}

/// Key of a session across PCs (session identity = pc id + session id).
String sessionKey(String pcId, String sessionId) => '$pcId:$sessionId';

/// One row of `sessions_cache` (written only by the task isolate): a session
/// plus which PC reported it.
class SessionEntry {
  const SessionEntry({required this.pcId, required this.pcName, required this.session});

  final String pcId;
  final String pcName;
  final CcSession session;

  String get key => sessionKey(pcId, session.id);

  factory SessionEntry.fromJson(Map<String, dynamic> j) => SessionEntry(
        pcId: _asString(j['pc_id']),
        pcName: _asString(j['pc_name']),
        session: CcSession.fromJson(Map<String, dynamic>.from(j['session'] as Map)),
      );

  Map<String, dynamic> toJson() => {
        'pc_id': pcId,
        'pc_name': pcName,
        'session': session.toJson(),
      };
}

/// Chat item roles (PROTOCOL.md v1.2 "Transcript → chat items").
class ChatRole {
  static const user = 'user';
  static const assistant = 'assistant';
  static const tool = 'tool';
  static const phone = 'phone';
}

/// One chat item of a session (fetched on demand, never persisted).
class ChatItem {
  const ChatItem({
    required this.id,
    required this.ts,
    required this.role,
    required this.text,
    this.tool = '',
    this.images = const <String>[],
    this.suggestions = const <String>[],
  });

  final String id;
  final int ts; // unix ms
  final String role;
  final String text;
  final String tool; // role tool only

  /// Ids of the message's images (v1.3), fetched with `get_image`.
  final List<String> images;

  /// Messages the user may want to send next (v1.5; a reply of Claude only).
  final List<String> suggestions;

  factory ChatItem.fromJson(Map<String, dynamic> j) => ChatItem(
        id: _asString(j['id']),
        ts: _asInt(j['ts']),
        role: _asString(j['role']),
        text: _asString(j['text']),
        tool: _asString(j['tool']),
        images: <String>[
          if (j['images'] is List)
            for (final e in j['images'] as List)
              if (e is Map && e['id'] is String && (e['id'] as String).isNotEmpty) e['id'] as String,
        ],
        suggestions: _asStringList(j['suggestions']),
      );

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);
}

/// Status of a message sent from the phone (`send_result`, plus the local
/// `sending` state until the PC answers).
class SendStatus {
  static const sending = 'sending';
  static const delivered = 'delivered';
  static const queued = 'queued';
  static const rejected = 'rejected';
}

/// User settings (`settings` pref, written only by the UI isolate).
class AppSettings {
  const AppSettings({
    this.notifyStop = true,
    this.notifyNeedsInput = true,
    this.notifySessionEnd = true,
    this.answerFromPhone = true,
    this.keepAlive = false,
    this.voiceLanguage = '',
    this.mutedProjects = const <String>[],
  });

  final bool notifyStop;
  final bool notifyNeedsInput;
  final bool notifySessionEnd;

  /// Show an action notification (Allow / Deny / options…) for requests.
  final bool answerFromPhone;

  /// iOS only: keep the app (and its connections) running in the background.
  final bool keepAlive;

  /// Language voice messages are spoken in ("en-US", "ar-SA"); empty = the
  /// phone's own language.
  final String voiceLanguage;
  final List<String> mutedProjects;

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        notifyStop: j['notify_stop'] is bool ? j['notify_stop'] as bool : true,
        notifyNeedsInput: j['notify_needs_input'] is bool ? j['notify_needs_input'] as bool : true,
        notifySessionEnd: j['notify_session_end'] is bool ? j['notify_session_end'] as bool : true,
        answerFromPhone: j['answer_from_phone'] is bool ? j['answer_from_phone'] as bool : true,
        keepAlive: j['keep_alive'] is bool ? j['keep_alive'] as bool : false,
        voiceLanguage: _asString(j['voice_language']),
        mutedProjects: _asStringList(j['muted_projects']),
      );

  Map<String, dynamic> toJson() => {
        'notify_stop': notifyStop,
        'notify_needs_input': notifyNeedsInput,
        'notify_session_end': notifySessionEnd,
        'answer_from_phone': answerFromPhone,
        'keep_alive': keepAlive,
        'voice_language': voiceLanguage,
        'muted_projects': mutedProjects,
      };

  AppSettings copyWith({
    bool? notifyStop,
    bool? notifyNeedsInput,
    bool? notifySessionEnd,
    bool? answerFromPhone,
    bool? keepAlive,
    String? voiceLanguage,
    List<String>? mutedProjects,
  }) =>
      AppSettings(
        notifyStop: notifyStop ?? this.notifyStop,
        notifyNeedsInput: notifyNeedsInput ?? this.notifyNeedsInput,
        notifySessionEnd: notifySessionEnd ?? this.notifySessionEnd,
        answerFromPhone: answerFromPhone ?? this.answerFromPhone,
        keepAlive: keepAlive ?? this.keepAlive,
        voiceLanguage: voiceLanguage ?? this.voiceLanguage,
        mutedProjects: mutedProjects ?? this.mutedProjects,
      );

  /// Whether an action notification may be shown for [r] (the request is
  /// always listed in the app).
  bool allowsRequest(CcRequest r) => answerFromPhone && !mutedProjects.contains(r.project);

  /// Whether a system notification may be shown for [e] (history is always kept).
  bool allows(CcEvent e) {
    if (mutedProjects.contains(e.project)) return false;
    switch (e.kind) {
      case EventKind.stop:
        return notifyStop;
      case EventKind.needsInput:
        return notifyNeedsInput;
      case EventKind.sessionEnd:
        return notifySessionEnd;
      default:
        return true;
    }
  }
}

/// The QR payload printed by `mewo pair` (PROTOCOL.md "QR payload").
class QrPayload {
  const QrPayload({
    required this.id,
    required this.name,
    required this.hosts,
    required this.port,
    required this.fp,
    required this.code,
  });

  final String id;
  final String name;
  final List<String> hosts;
  final int port;
  final String fp;
  final String code;

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// Parses and validates a raw QR string. Throws [FormatException] with a
  /// user-readable message when invalid.
  static QrPayload parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw.trim());
    } catch (_) {
      throw const FormatException('This is not a Mewo on Fire pairing code.');
    }
    if (decoded is! Map) {
      throw const FormatException('This is not a Mewo on Fire pairing code.');
    }
    final j = Map<String, dynamic>.from(decoded);
    if (_asInt(j['v'], -1) != 1) {
      throw const FormatException(
          'Unsupported pairing code version. Update Mewo on Fire on the PC and on this phone.');
    }
    final id = _asString(j['id']);
    final name = _asString(j['name']);
    final hosts = _asStringList(j['hosts']);
    final port = _asInt(j['port']);
    final fp = _asString(j['fp']).toLowerCase();
    final code = _asString(j['code']);
    if (id.isEmpty || code.isEmpty) {
      throw const FormatException('Pairing code is missing the PC id or code.');
    }
    if (hosts.isEmpty) {
      throw const FormatException(
          'The PC did not report any network address. Is it connected to the LAN?');
    }
    if (port <= 0 || port > 65535) {
      throw const FormatException('Pairing code has an invalid port.');
    }
    if (!_hex64.hasMatch(fp)) {
      throw const FormatException('Pairing code has an invalid certificate fingerprint.');
    }
    return QrPayload(
      id: id,
      name: name.isEmpty ? id : name,
      hosts: hosts,
      port: port,
      fp: fp,
      code: code,
    );
  }
}

/// One check of a pull request (PROTOCOL.md v1.6): `pass`, `fail` or `pending`.
class PrCheck {
  const PrCheck({required this.name, required this.state});

  final String name;
  final String state;

  factory PrCheck.fromJson(Map<String, dynamic> j) =>
      PrCheck(name: _asString(j['name']), state: _asString(j['state']));
}

/// An open pull request of the session's repository (PROTOCOL.md v1.6).
class PullRequest {
  const PullRequest({
    required this.number,
    this.title = '',
    this.branch = '',
    this.url = '',
    this.additions = 0,
    this.deletions = 0,
    this.draft = false,
    this.review = '',
    this.ci = 'none',
    this.checks = const <PrCheck>[],
    this.author = '',
    this.current = false,
  });

  final int number;
  final String title;
  final String branch;
  final String url;
  final int additions;
  final int deletions;
  final bool draft;

  /// `approved`, `changes`, `required` or empty.
  final String review;

  /// `pass`, `fail`, `pending` or `none`.
  final String ci;
  final List<PrCheck> checks;
  final String author;

  /// Its branch is the one checked out in the session's folder.
  final bool current;

  factory PullRequest.fromJson(Map<String, dynamic> j) => PullRequest(
        number: _asInt(j['number']),
        title: _asString(j['title']),
        branch: _asString(j['branch']),
        url: _asString(j['url']),
        additions: _asInt(j['additions']),
        deletions: _asInt(j['deletions']),
        draft: j['draft'] == true,
        review: _asString(j['review']),
        ci: _asString(j['ci']).isEmpty ? 'none' : _asString(j['ci']),
        checks: <PrCheck>[
          if (j['checks'] is List)
            for (final c in j['checks'] as List)
              if (c is Map) PrCheck.fromJson(Map<String, dynamic>.from(c)),
        ],
        author: _asString(j['author']),
        current: j['current'] == true,
      );
}

/// The pull requests of one session's repository, as last heard from the PC.
class PrList {
  const PrList({
    this.repo = '',
    this.branch = '',
    this.prs = const <PullRequest>[],
    this.error = '',
    this.loading = false,
    this.loaded = false,
  });

  final String repo;
  final String branch;
  final List<PullRequest> prs;
  final String error;
  final bool loading;
  final bool loaded;

  factory PrList.fromJson(Map<String, dynamic> j) => PrList(
        repo: _asString(j['repo']),
        branch: _asString(j['branch']),
        prs: <PullRequest>[
          if (j['prs'] is List)
            for (final p in j['prs'] as List)
              if (p is Map) PullRequest.fromJson(Map<String, dynamic>.from(p)),
        ],
        error: _asString(j['error']),
        loaded: true,
      );

  PrList copyWith({bool? loading, String? error}) => PrList(
        repo: repo,
        branch: branch,
        prs: prs,
        error: error ?? this.error,
        loading: loading ?? this.loading,
        loaded: loaded,
      );
}
