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
  });

  final int id;
  final int ts; // unix ms
  final String kind;
  final String project;
  final String cwd;
  final String session;
  final String message;
  final String detail;

  factory CcEvent.fromJson(Map<String, dynamic> j) => CcEvent(
        id: _asInt(j['id']),
        ts: _asInt(j['ts']),
        kind: _asString(j['kind']),
        project: _asString(j['project']),
        cwd: _asString(j['cwd']),
        session: _asString(j['session']),
        message: _asString(j['message']),
        detail: _asString(j['detail']),
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

/// User settings (`settings` pref, written only by the UI isolate).
class AppSettings {
  const AppSettings({
    this.notifyStop = true,
    this.notifyNeedsInput = true,
    this.notifySessionEnd = true,
    this.mutedProjects = const <String>[],
  });

  final bool notifyStop;
  final bool notifyNeedsInput;
  final bool notifySessionEnd;
  final List<String> mutedProjects;

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        notifyStop: j['notify_stop'] is bool ? j['notify_stop'] as bool : true,
        notifyNeedsInput: j['notify_needs_input'] is bool ? j['notify_needs_input'] as bool : true,
        notifySessionEnd: j['notify_session_end'] is bool ? j['notify_session_end'] as bool : true,
        mutedProjects: _asStringList(j['muted_projects']),
      );

  Map<String, dynamic> toJson() => {
        'notify_stop': notifyStop,
        'notify_needs_input': notifyNeedsInput,
        'notify_session_end': notifySessionEnd,
        'muted_projects': mutedProjects,
      };

  AppSettings copyWith({
    bool? notifyStop,
    bool? notifyNeedsInput,
    bool? notifySessionEnd,
    List<String>? mutedProjects,
  }) =>
      AppSettings(
        notifyStop: notifyStop ?? this.notifyStop,
        notifyNeedsInput: notifyNeedsInput ?? this.notifyNeedsInput,
        notifySessionEnd: notifySessionEnd ?? this.notifySessionEnd,
        mutedProjects: mutedProjects ?? this.mutedProjects,
      );

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

/// The QR payload printed by `ccnotify pair` (PROTOCOL.md "QR payload").
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
      throw const FormatException('This is not a ccnotify pairing code.');
    }
    if (decoded is! Map) {
      throw const FormatException('This is not a ccnotify pairing code.');
    }
    final j = Map<String, dynamic>.from(decoded);
    if (_asInt(j['v'], -1) != 1) {
      throw const FormatException(
          'Unsupported pairing code version. Update ccnotify on the PC and on this phone.');
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
