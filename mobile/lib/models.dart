import 'dart:convert';

/// Event kinds defined by PROTOCOL.md.
class EventKind {
  static const stop = 'stop';
  static const needsInput = 'needs_input';
  static const sessionEnd = 'session_end';

  /// v1.7 (TORCH policy): a guard rail spoke up, a signature is asked for.
  static const warning = 'warning';
  static const signoff = 'signoff';
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
  const SessionArtifact({
    required this.url,
    this.title = '',
    this.kind = 'artifact',
    this.ts = 0,
    this.id = '',
    this.local = false,
    this.entry = '',
  });

  final String url;
  final String title;

  /// The last segment of the url; the folder of the PC's copy.
  final String id;

  /// The PC kept the files: the app can show it in place.
  final bool local;

  /// What to open in the copy: a design's `canvas.json`, a page, a `.md`.
  final String entry;

  /// `design`, `document`, `page` or `artifact`.
  final String kind;
  final int ts;

  factory SessionArtifact.fromJson(Map<String, dynamic> j) => SessionArtifact(
        url: _asString(j['url']),
        title: _asString(j['title']),
        kind: _asString(j['kind']).isEmpty ? 'artifact' : _asString(j['kind']),
        ts: _asInt(j['ts']),
        id: _asString(j['id']),
        local: j['local'] == true,
        entry: _asString(j['entry']),
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'kind': kind,
        'ts': ts,
        if (id.isNotEmpty) 'id': id,
        if (local) 'local': true,
        if (entry.isNotEmpty) 'entry': entry,
      };

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
    this.branch = '',
    this.model = '',
    this.tier = 0,
    this.feature = '',
    this.planSession = 0,
    this.checks = const <bool>[],
  });

  /// v1.7 (TORCH policy): the git branch, the model and its tier, the
  /// feature (`app/slug`) and plan session, the owner's self-check.
  final String branch;
  final String model;
  final int tier;
  final String feature;
  final int planSession;
  final List<bool> checks;

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
        branch: _asString(j['branch']),
        model: _asString(j['model']),
        tier: _asInt(j['tier']),
        feature: _asString(j['feature']),
        planSession: _asInt(j['plan_session']),
        checks: j['checks'] is List ? (j['checks'] as List).map((e) => e == true).toList() : const <bool>[],
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
        if (branch.isNotEmpty) 'branch': branch,
        if (model.isNotEmpty) 'model': model,
        if (tier != 0) 'tier': tier,
        if (feature.isNotEmpty) 'feature': feature,
        if (planSession != 0) 'plan_session': planSession,
        if (checks.isNotEmpty) 'checks': checks,
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
    this.signerName = '',
  });

  /// v1.7: the name written into a record when signing from this phone.
  final String signerName;

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
        signerName: _asString(j['signer_name']),
      );

  Map<String, dynamic> toJson() => {
        'notify_stop': notifyStop,
        'notify_needs_input': notifyNeedsInput,
        'notify_session_end': notifySessionEnd,
        'answer_from_phone': answerFromPhone,
        'keep_alive': keepAlive,
        'voice_language': voiceLanguage,
        'muted_projects': mutedProjects,
        'signer_name': signerName,
      };

  AppSettings copyWith({
    bool? notifyStop,
    bool? notifyNeedsInput,
    bool? notifySessionEnd,
    bool? answerFromPhone,
    bool? keepAlive,
    String? voiceLanguage,
    List<String>? mutedProjects,
    String? signerName,
  }) =>
      AppSettings(
        notifyStop: notifyStop ?? this.notifyStop,
        notifyNeedsInput: notifyNeedsInput ?? this.notifyNeedsInput,
        notifySessionEnd: notifySessionEnd ?? this.notifySessionEnd,
        answerFromPhone: answerFromPhone ?? this.answerFromPhone,
        keepAlive: keepAlive ?? this.keepAlive,
        voiceLanguage: voiceLanguage ?? this.voiceLanguage,
        mutedProjects: mutedProjects ?? this.mutedProjects,
        signerName: signerName ?? this.signerName,
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
      case EventKind.warning:
      case EventKind.signoff:
        return notifyNeedsInput;
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

// ---- v1.7: the TORCH Agentic Development Policy ----

/// Checklist F (session self-check), as the pull request template lists it.
const List<String> kSelfCheck = <String>[
  'I read the whole diff, and I can explain every line.',
  'The session\'s "done when" checks pass.',
  'Tests exist for the new behaviour and they test behaviour, not just that the code runs.',
  'The change stays inside the session\'s goal.',
  'Glare components and variables are used. No hardcoded design values.',
  'The rule files listed in the session plan were followed.',
  'No secrets, keys or personal data in the code or the commit.',
  'Lint, type check and the full test suite pass locally.',
];

/// Checklists G and H (reviewer).
const List<String> kReviewCheck = <String>[
  'Does what the session goal says; the PRD items it touches are met.',
  'Follows the architecture and patterns already in the repository.',
  'Reuses Glare, platform services and existing modules instead of copying them.',
  'Errors are handled properly and not hidden.',
  'Permissions and data access are checked on the server where they need to be.',
  'The tests would fail if the feature broke. No tests edited only so they pass.',
  'Matches the handoff HTML on screen.',
  'No duplicated code, unexplained dependencies, leftover TODOs, debug logs or placeholder text.',
  'No comments that just restate the code; nothing much larger than the task needed.',
  'Names match the domain language in the PRD and the existing code.',
  'I would have accepted this code if a person had written it.',
];

class GateItem {
  const GateItem({required this.text, required this.checked});
  final String text;
  final bool checked;
}

/// A sign-off point of a feature: a checklist and who signed it.
class TorchGate {
  const TorchGate({
    required this.id,
    required this.checklist,
    required this.title,
    required this.step,
    required this.file,
    required this.items,
    required this.roles,
    required this.signatures,
    required this.date,
    required this.signed,
    required this.present,
  });

  final String id;
  final String checklist;
  final String title;
  final int step;
  final String file;
  final List<GateItem> items;
  final List<String> roles;

  /// role → name.
  final Map<String, String> signatures;
  final String date;
  final bool signed;
  final bool present;

  List<String> get openRoles => [for (final r in roles) if (!signatures.containsKey(r)) r];

  factory TorchGate.fromJson(Map<String, dynamic> j) => TorchGate(
        id: _asString(j['id']),
        checklist: _asString(j['checklist']),
        title: _asString(j['title']),
        step: _asInt(j['step']),
        file: _asString(j['file']),
        items: [
          if (j['items'] is List)
            for (final i in j['items'] as List)
              if (i is Map) GateItem(text: _asString(i['text']), checked: i['checked'] == true),
        ],
        roles: _asStringList(j['roles']),
        signatures: {
          if (j['signatures'] is List)
            for (final s in j['signatures'] as List)
              if (s is Map) _asString(s['role']): _asString(s['name']),
        },
        date: _asString(j['date']),
        signed: j['signed'] == true,
        present: j['present'] == true,
      );
}

class LiveSession {
  const LiveSession({required this.id, required this.short, required this.state, required this.tier, required this.title});
  final String id;
  final String short;
  final String state;
  final int tier;
  final String title;
}

/// One session of a feature's plan, with what the PC knows about it.
class PlanSession {
  const PlanSession({
    required this.n,
    required this.goal,
    required this.level,
    required this.tier,
    required this.dependsOn,
    required this.owner,
    required this.status,
    required this.loadFirst,
    required this.prompt,
    required this.doneWhen,
    required this.pr,
    required this.repo,
    required this.folder,
    required this.effective,
    required this.note,
    required this.running,
    required this.attempts,
    required this.live,
    required this.prState,
    required this.prUrl,
    required this.prNumber,
    required this.warnings,
  });

  final int n;
  final String goal;
  final String level;
  final int tier;
  final List<int> dependsOn;
  final String owner;
  final String status;
  final List<String> loadFirst;
  final String prompt;
  final List<String> doneWhen;
  final String pr;
  final String repo;
  final String folder;

  /// `merged`, `review`, `progress`, `blocked`, `waiting`, `ready`.
  final String effective;
  final String note;
  final bool running;
  final int attempts;
  final List<LiveSession> live;
  final String prState;
  final String prUrl;
  final int prNumber;
  final List<String> warnings;

  String get statusLabel {
    switch (effective) {
      case 'merged':
        return 'Merged';
      case 'review':
        return 'In review';
      case 'progress':
        return 'In progress';
      case 'blocked':
        return 'Blocked';
      case 'waiting':
        return 'Waiting';
      default:
        return 'Ready';
    }
  }

  factory PlanSession.fromJson(Map<String, dynamic> j) => PlanSession(
        n: _asInt(j['n']),
        goal: _asString(j['goal']),
        level: _asString(j['level']),
        tier: _asInt(j['tier']),
        dependsOn: j['depends_on'] is List ? (j['depends_on'] as List).map((e) => _asInt(e)).toList() : const <int>[],
        owner: _asString(j['owner']),
        status: _asString(j['status']),
        loadFirst: _asStringList(j['load_first']),
        prompt: _asString(j['prompt']),
        doneWhen: _asStringList(j['done_when']),
        pr: _asString(j['pr']),
        repo: _asString(j['repo']),
        folder: _asString(j['folder']),
        effective: _asString(j['effective']),
        note: _asString(j['note']),
        running: j['running'] == true,
        attempts: _asInt(j['attempts']),
        live: [
          if (j['live'] is List)
            for (final l in j['live'] as List)
              if (l is Map)
                LiveSession(id: _asString(l['id']), short: _asString(l['short']), state: _asString(l['state']), tier: _asInt(l['tier']), title: _asString(l['title'])),
        ],
        prState: _asString(j['pr_state']),
        prUrl: _asString(j['pr_url']),
        prNumber: _asInt(j['pr_number']),
        warnings: _asStringList(j['warnings']),
      );
}

class TorchPlan {
  const TorchPlan({required this.file, required this.prd, required this.reviewedBy, required this.revised, required this.sessions});
  final String file;
  final String prd;
  final String reviewedBy;
  final List<String> revised;
  final List<PlanSession> sessions;

  factory TorchPlan.fromJson(Map<String, dynamic> j) => TorchPlan(
        file: _asString(j['file']),
        prd: _asString(j['prd']),
        reviewedBy: _asString(j['reviewed_by']),
        revised: _asStringList(j['revised']),
        sessions: [
          if (j['sessions'] is List)
            for (final s in j['sessions'] as List)
              if (s is Map) PlanSession.fromJson(Map<String, dynamic>.from(s)),
        ],
      );
}

/// What the flow does next for a feature (v1.8).
class FlowAction {
  const FlowAction({required this.kind, required this.step, required this.title, required this.detail, required this.gate, required this.roles, required this.session, required this.auto});
  final String kind;
  final int step;
  final String title;
  final String detail;
  final String gate;
  final List<String> roles;
  final int session;
  final bool auto;

  factory FlowAction.fromJson(Map<String, dynamic> j) => FlowAction(
        kind: _asString(j['kind']),
        step: _asInt(j['step']),
        title: _asString(j['title']),
        detail: _asString(j['detail']),
        gate: _asString(j['gate']),
        roles: _asStringList(j['roles']),
        session: _asInt(j['session']),
        auto: j['auto'] == true,
      );

  static const empty = FlowAction(kind: '', step: 0, title: '', detail: '', gate: '', roles: <String>[], session: 0, auto: false);
}

class FlowEstimate {
  const FlowEstimate({required this.role, required this.name, required this.days, required this.assumptions});
  final String role;
  final String name;
  final double days;
  final String assumptions;
}

/// One write the flow made, and whether it can be rolled back (v1.9).
class FlowJournal {
  const FlowJournal({required this.id, required this.ts, required this.kind, required this.title, required this.commit, required this.files, required this.undoable, required this.undone});
  final int id;
  final int ts;
  final String kind;
  final String title;
  final String commit;
  final List<String> files;
  final bool undoable;
  final bool undone;

  factory FlowJournal.fromJson(Map<String, dynamic> j) => FlowJournal(
        id: _asInt(j['id']),
        ts: _asInt(j['ts']),
        kind: _asString(j['kind']),
        title: _asString(j['title']),
        commit: _asString(j['commit']),
        files: _asStringList(j['files']),
        undoable: j['undoable'] == true,
        undone: j['undone'] == true,
      );
}

/// The flow runner's state for a feature (v1.8).
class FlowInfo {
  const FlowInfo({required this.autopilot, required this.estimates, required this.estimatesDone, required this.log, required this.releasedAt, required this.closedAt, required this.action, this.history = const <FlowJournal>[], this.buildOn = false, this.buildParallel = 2, this.buildReview = true});

  /// v2.6: the build autopilot.
  final bool buildOn;
  final int buildParallel;
  final bool buildReview;
  final List<FlowJournal> history;
  final bool autopilot;
  final List<FlowEstimate> estimates;
  final bool estimatesDone;
  final List<(int, String)> log;
  final int releasedAt;
  final int closedAt;
  final FlowAction action;

  static const empty = FlowInfo(autopilot: false, estimates: <FlowEstimate>[], estimatesDone: false, log: <(int, String)>[], releasedAt: 0, closedAt: 0, action: FlowAction.empty);

  factory FlowInfo.fromJson(Map<String, dynamic> j) => FlowInfo(
        autopilot: j['autopilot'] == true,
        buildOn: j['build'] is Map && (j['build'] as Map)['on'] == true,
        buildParallel: j['build'] is Map ? _asInt((j['build'] as Map)['parallel']) : 2,
        buildReview: !(j['build'] is Map && (j['build'] as Map)['review'] == false),
        estimates: [
          if (j['estimates'] is List)
            for (final e in j['estimates'] as List)
              if (e is Map) FlowEstimate(role: _asString(e['role']), name: _asString(e['name']), days: e['days'] is num ? (e['days'] as num).toDouble() : 0, assumptions: _asString(e['assumptions'])),
        ],
        estimatesDone: j['estimates_done'] == true,
        log: [
          if (j['log'] is List)
            for (final e in j['log'] as List)
              if (e is Map) (_asInt(e['ts']), _asString(e['text'])),
        ],
        releasedAt: _asInt(j['released_at']),
        closedAt: _asInt(j['closed_at']),
        action: j['action'] is Map ? FlowAction.fromJson(Map<String, dynamic>.from(j['action'] as Map)) : FlowAction.empty,
        history: [
          if (j['history'] is List)
            for (final h in j['history'] as List)
              if (h is Map) FlowJournal.fromJson(Map<String, dynamic>.from(h)),
        ],
      );
}

class RoleEntry {
  const RoleEntry({required this.role, required this.name, required this.phone, this.pc = '', this.plane = ''});
  final String role;
  final String name;
  final String phone;
  final String pc;
  final String plane;
}

/// A work item in Plane that mirrors a gate or a session (v2.1).
class PlaneItem {
  const PlaneItem({required this.id, required this.url, required this.group, required this.assignees, required this.sequenceId});
  final String id;
  final String url;
  final String group;
  final List<String> assignees;
  final int sequenceId;

  factory PlaneItem.fromJson(Map<String, dynamic> j) => PlaneItem(
        id: _asString(j['id']),
        url: _asString(j['url']),
        group: _asString(j['group']),
        assignees: _asStringList(j['assignees']),
        sequenceId: _asInt(j['sequence_id']),
      );
}

/// The Plane connection of a PC, as the phones see it (no token).
class PlaneInfo {
  const PlaneInfo({required this.configured, required this.workspace, required this.projectName, required this.appUrl, required this.people});
  final bool configured;
  final String workspace;
  final String projectName;
  final String appUrl;

  /// phone device name → display name of who signed in there.
  final Map<String, String> people;

  static const none = PlaneInfo(configured: false, workspace: '', projectName: '', appUrl: '', people: <String, String>{});

  factory PlaneInfo.fromJson(Map<String, dynamic> j) => PlaneInfo(
        configured: j['configured'] == true,
        workspace: _asString(j['workspace']),
        projectName: _asString(j['project_name']),
        appUrl: _asString(j['app_url']),
        people: {
          if (j['people'] is List)
            for (final p in j['people'] as List)
              if (p is Map) _asString(p['phone']): _asString(p['display']),
        },
      );
}

/// A Plane item assigned to me (v2.1).
class MineItem {
  const MineItem({required this.feature, required this.item, required this.name, required this.group, required this.url});
  final String feature;
  final String item;
  final String name;
  final String group;
  final String url;

  factory MineItem.fromJson(Map<String, dynamic> j) => MineItem(feature: _asString(j['feature']), item: _asString(j['item']), name: _asString(j['name']), group: _asString(j['group']), url: _asString(j['url']));
}

/// A task under a session's Plane item.
class PlaneTask {
  const PlaneTask({required this.id, required this.name, required this.done, required this.url, required this.sequenceId});
  final String id;
  final String name;
  final bool done;
  final String url;
  final int sequenceId;

  factory PlaneTask.fromJson(Map<String, dynamic> j) => PlaneTask(id: _asString(j['id']), name: _asString(j['name']), done: j['done'] == true, url: _asString(j['url']), sequenceId: _asInt(j['sequence_id']));
}

/// A feature of a TORCH workspace and where it stands in the twelve steps.
class TorchFeature {
  const TorchFeature({
    required this.key,
    required this.app,
    required this.slug,
    required this.branch,
    required this.light,
    required this.workspace,
    required this.step,
    required this.stepLabel,
    required this.released,
    required this.gates,
    required this.plan,
    required this.handoffFiles,
    required this.handoffId,
    required this.openQuestions,
    required this.repos,
    required this.prd,
    required this.prdSigned,
    required this.warnings,
    required this.sessionsMerged,
    required this.sessionsTotal,
    this.prdSource = '',
    this.design = DesignInfo.policyDefault,
    this.flow = FlowInfo.empty,
    this.planeParentUrl = '',
    this.planeItems = const <String, PlaneItem>{},
  });

  final FlowInfo flow;
  final String planeParentUrl;

  /// Where the PRD came from: `plan`, `feature`, `app`, or `picked` (v2.2).
  final String prdSource;

  /// v2.3: the design system the feature follows (Glare unless recorded).
  final DesignInfo design;

  /// `gate:<id>`, `prd`, `estimates`, `session:<n>` → the Plane item.
  final Map<String, PlaneItem> planeItems;

  static const List<String> steps = <String>[
    'PRD draft',
    'Estimates',
    'Alignment and sign-off',
    'Design process',
    'Prototype and test',
    'Handoff session',
    'Handoff intake',
    'Session planning',
    'Build sessions',
    'Staging',
    'UAT',
    'Production',
  ];

  final String key;
  final String app;
  final String slug;
  final String branch;
  final bool light;
  final String workspace;
  final int step;
  final String stepLabel;
  final bool released;
  final List<TorchGate> gates;
  final TorchPlan? plan;
  final List<String> handoffFiles;
  final String handoffId;
  final int openQuestions;
  final List<String> repos;
  final String prd;
  final bool prdSigned;
  final List<String> warnings;
  final int sessionsMerged;
  final int sessionsTotal;

  bool get running => plan?.sessions.any((s) => s.running) ?? false;
  int get warningCount => warnings.length + (plan?.sessions.fold<int>(0, (a, s) => a + s.warnings.length) ?? 0);

  factory TorchFeature.fromJson(Map<String, dynamic> j) => TorchFeature(
        key: _asString(j['key']),
        app: _asString(j['app']),
        slug: _asString(j['slug']),
        branch: _asString(j['branch']),
        light: j['light'] == true,
        workspace: _asString(j['workspace']),
        step: _asInt(j['step']),
        stepLabel: _asString(j['step_label']),
        released: j['released'] == true,
        gates: [
          if (j['gates'] is List)
            for (final g in j['gates'] as List)
              if (g is Map) TorchGate.fromJson(Map<String, dynamic>.from(g)),
        ],
        plan: j['plan'] is Map ? TorchPlan.fromJson(Map<String, dynamic>.from(j['plan'] as Map)) : null,
        handoffFiles: _asStringList(j['handoff_files']),
        handoffId: _asString(j['handoff_id']),
        openQuestions: _asInt(j['open_questions']),
        repos: _asStringList(j['repos']),
        prd: _asString(j['prd']),
        prdSigned: j['prd_signed'] == true,
        prdSource: _asString(j['prd_source']),
        design: j['design'] is Map ? DesignInfo.fromJson(Map<String, dynamic>.from(j['design'] as Map)) : DesignInfo.policyDefault,
        warnings: _asStringList(j['warnings']),
        sessionsMerged: _asInt(j['sessions_merged']),
        sessionsTotal: _asInt(j['sessions_total']),
        flow: j['flow'] is Map ? FlowInfo.fromJson(Map<String, dynamic>.from(j['flow'] as Map)) : FlowInfo.empty,
        planeParentUrl: j['plane'] is Map ? _asString((j['plane'] as Map)['parent_url']) : '',
        planeItems: {
          if (j['plane'] is Map && (j['plane'] as Map)['items'] is Map)
            for (final e in ((j['plane'] as Map)['items'] as Map).entries)
              if (e.value is Map) '${e.key}': PlaneItem.fromJson(Map<String, dynamic>.from(e.value as Map)),
        },
      );
}

/// The design system a feature follows (v2.3), from DESIGN_SYSTEM.md in
/// its folder; Glare, the policy's default, when there is no record.
class DesignInfo {
  const DesignInfo({required this.name, required this.repo, required this.dir, required this.reference, required this.present, required this.checkedOut, required this.glare});

  /// The policy's default: Glare, with its rules in context/rules/.
  static const DesignInfo policyDefault = DesignInfo(name: 'Glare', repo: '', dir: '', reference: 'context/rules/', present: false, checkedOut: true, glare: true);

  final String name;
  final String repo;

  /// The checkout, relative to the workspace (`code/tauri-templete`).
  final String dir;

  /// What to read first: where its shell, components and tokens are.
  final String reference;
  final bool present;
  final bool checkedOut;
  final bool glare;

  factory DesignInfo.fromJson(Map<String, dynamic> j) => DesignInfo(
        name: _asString(j['name']).isEmpty ? 'Glare' : _asString(j['name']),
        repo: _asString(j['repo']),
        dir: _asString(j['dir']),
        reference: _asString(j['reference']),
        present: j['present'] == true,
        checkedOut: j['checked_out'] != false,
        glare: j['glare'] != false,
      );
}

/// A PRD family of the workspace (v2.2): the newest `{stem}_PRD_V….md`.
class PrdChoice {
  const PrdChoice({required this.stem, required this.display, required this.file, required this.folder, required this.version, required this.signed, required this.current});

  final String stem;
  final String display;
  final String file;
  final String folder;
  final String version;
  final bool signed;

  /// Picked for the feature by hand.
  final bool current;

  factory PrdChoice.fromJson(Map<String, dynamic> j) => PrdChoice(
        stem: _asString(j['stem']),
        display: _asString(j['display']),
        file: _asString(j['file']),
        folder: _asString(j['folder']),
        version: _asString(j['version']),
        signed: j['signed'] == true,
        current: j['current'] == true,
      );
}

/// The features of one PC, with the policy's checklist texts.
class FeaturesData {
  const FeaturesData({
    required this.features,
    required this.selfCheck,
    required this.reviewCheck,
    this.error = '',
    this.ts = 0,
    this.workspaces = const <String>[],
    this.roles = const <String, List<RoleEntry>>{},
    this.apps = const <String, List<String>>{},
    this.roleNames = const <String>[],
    this.warning = '',
    this.plane = PlaneInfo.none,
  });
  final PlaneInfo plane;
  final List<TorchFeature> features;
  final List<String> selfCheck;
  final List<String> reviewCheck;
  final String error;
  final int ts;
  final List<String> workspaces;

  /// workspace → who holds each role.
  final Map<String, List<RoleEntry>> roles;
  final Map<String, List<String>> apps;
  final List<String> roleNames;
  final String warning;

  factory FeaturesData.fromJson(Map<String, dynamic> j) => FeaturesData(
        features: [
          if (j['features'] is List)
            for (final f in j['features'] as List)
              if (f is Map) TorchFeature.fromJson(Map<String, dynamic>.from(f)),
        ],
        selfCheck: _asStringList(j['self_check']),
        reviewCheck: _asStringList(j['review_check']),
        error: _asString(j['error']),
        ts: DateTime.now().millisecondsSinceEpoch,
        workspaces: _asStringList(j['workspaces']),
        roles: {
          if (j['roles'] is Map)
            for (final e in (j['roles'] as Map).entries)
              '${e.key}': [
                if (e.value is List)
                  for (final r in e.value as List)
                    if (r is Map) RoleEntry(role: _asString(r['role']), name: _asString(r['name']), phone: _asString(r['phone']), pc: _asString(r['pc']), plane: _asString(r['plane'])),
              ],
        },
        apps: {
          if (j['apps'] is Map)
            for (final e in (j['apps'] as Map).entries) '${e.key}': _asStringList(e.value),
        },
        roleNames: _asStringList(j['role_names']),
        warning: _asString(j['warning']),
        plane: j['plane'] is Map ? PlaneInfo.fromJson(Map<String, dynamic>.from(j['plane'] as Map)) : PlaneInfo.none,
      );
}

class ScanFinding {
  const ScanFinding({required this.rule, required this.file, required this.line, required this.text});
  final String rule;
  final String file;
  final int line;
  final String text;
}

/// The self-check scan of a session's changes (policy 8.5).
class ScanReport {
  const ScanReport({required this.ok, required this.error, required this.base, required this.files, required this.additions, required this.deletions, required this.findings, required this.counts});
  final bool ok;
  final String error;
  final String base;
  final int files;
  final int additions;
  final int deletions;
  final List<ScanFinding> findings;

  /// label → count.
  final List<(String, int)> counts;

  factory ScanReport.fromJson(Map<String, dynamic> j) => ScanReport(
        ok: j['ok'] == true,
        error: _asString(j['error']),
        base: _asString(j['base']),
        files: _asInt(j['files']),
        additions: _asInt(j['additions']),
        deletions: _asInt(j['deletions']),
        findings: [
          if (j['findings'] is List)
            for (final f in j['findings'] as List)
              if (f is Map) ScanFinding(rule: _asString(f['rule']), file: _asString(f['file']), line: _asInt(f['line']), text: _asString(f['text'])),
        ],
        counts: [
          if (j['counts'] is List)
            for (final c in j['counts'] as List)
              if (c is Map) (_asString(c['label']), _asInt(c['n'])),
        ],
      );
}
