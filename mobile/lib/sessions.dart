import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;

import 'models.dart';
import 'requests.dart' show DarwinCategory, kAnswerPortName;
import 'storage.dart';

/// Session chat + continuing a session from the phone (PROTOCOL.md v1.2):
/// the `send` message, the event notification payload, the **Reply** action
/// of `stop` notifications and its background handler.
///
/// Routing of messages to the task isolate (the only owner of PC connections)
/// is the same as for v1.1 answers:
/// - UI isolate → `FlutterForegroundTask.sendDataToTask({"cmd":"send",...})`
///   (see `AppState.sendMessage`), or the queue when the service is not running.
/// - Reply action → [routeActionReply] in the plugin's background isolate →
///   the task's ReceivePort registered under [kAnswerPortName], or the queue
///   (`queued_send_*`, see `Store`) when the task is not running.

/// Action id of the Reply button on `stop` notifications.
const String kReplyActionId = 'reply';

/// Channel of `stop` notifications (also used when a reply updates one).
const fln.AndroidNotificationChannel kStopChannel = fln.AndroidNotificationChannel(
  'stop',
  'Finished',
  description: 'Claude Code finished a reply.',
  importance: fln.Importance.defaultImportance,
);

final Random _rand = Random.secure();

/// Random 16-hex id correlating a `send` with its `send_result`.
String newClientId() =>
    List<String>.generate(16, (_) => _rand.nextInt(16).toRadixString(16)).join();

/// The notification a Reply was typed into; the task updates it with the
/// result ("Sent: …" / "Queued: …" / "Couldn't send: …").
class ReplyNotif {
  const ReplyNotif({
    required this.id,
    this.eventId = 0,
    this.title = '',
    this.pcName = '',
  });

  final int id;
  final int eventId;
  final String title;
  final String pcName;

  Map<String, dynamic> toJson() => {
        'id': id,
        'event_id': eventId,
        'title': title,
        'pc_name': pcName,
      };

  static ReplyNotif? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! int || id == 0) return null;
    final eventId = j['event_id'];
    final title = j['title'];
    final pcName = j['pc_name'];
    return ReplyNotif(
      id: id,
      eventId: eventId is int ? eventId : 0,
      title: title is String ? title : '',
      pcName: pcName is String ? pcName : '',
    );
  }
}

/// Message understood by the task isolate (port, sendDataToTask and queue).
/// [images] (v1.3): `{"mime", "data": <base64>}` each.
Map<String, dynamic> sendCmd(
  String pcId,
  String sessionId,
  String text,
  String clientId, {
  ReplyNotif? notif,
  List<Map<String, String>> images = const <Map<String, String>>[],
}) =>
    {
      'cmd': 'send',
      'pc_id': pcId,
      'session_id': sessionId,
      'text': text,
      'client_id': clientId,
      if (notif != null) 'notif': notif.toJson(),
      if (images.isNotEmpty) 'images': images,
    };

/// Payload of an event notification (`stop` / `needs_input` / `session_end`):
/// tapping it opens the session's chat, the Reply action sends to the session.
class EventPayload {
  const EventPayload({
    required this.pcId,
    this.sessionId = '',
    this.eventId = 0,
    this.kind = '',
    this.title = '',
    this.pcName = '',
  });

  final String pcId;
  final String sessionId;
  final int eventId;
  final String kind;
  final String title; // notification title (to update it after a reply)
  final String pcName;

  static const _type = 'event';

  String encode() => jsonEncode({
        'type': _type,
        'pc_id': pcId,
        if (sessionId.isNotEmpty) 'session_id': sessionId,
        'event_id': eventId,
        'kind': kind,
        'title': title,
        'pc_name': pcName,
      });

  /// Null for other notifications (v1.0 event notifications carried the
  /// plain pc id; request notifications carry a `RequestPayload`).
  static EventPayload? tryParse(String? raw) {
    if (raw == null || !raw.startsWith('{')) return null;
    try {
      final d = jsonDecode(raw);
      if (d is! Map || d['type'] != _type) return null;
      final pcId = d['pc_id'];
      if (pcId is! String || pcId.isEmpty) return null;
      String s(Object? v) => v is String ? v : '';
      final eventId = d['event_id'];
      return EventPayload(
        pcId: pcId,
        sessionId: s(d['session_id']),
        eventId: eventId is int ? eventId : 0,
        kind: s(d['kind']),
        title: s(d['title']),
        pcName: s(d['pc_name']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The Reply button with inline text input (RemoteInput). The notification is
/// not cancelled: Android shows a spinner until it is updated with the result.
fln.AndroidNotificationAction replyAction() => const fln.AndroidNotificationAction(
      kReplyActionId,
      'Reply',
      showsUserInterface: false,
      cancelNotification: false,
      inputs: <fln.AndroidNotificationActionInput>[
        fln.AndroidNotificationActionInput(label: 'Message to Claude'),
      ],
    );

/// Notification body for a reply result.
String replyStatusText(String status, String text, String reason) {
  switch (status) {
    case SendStatus.sending:
      return 'Sending: $text';
    case SendStatus.delivered:
      return 'Sent: $text';
    case SendStatus.queued:
      return 'Queued: $text';
    default:
      return "Couldn't send: ${reason.isEmpty ? 'rejected by the PC' : reason}";
  }
}

/// Replaces the replied-to notification [notif] with [body] (silently). With
/// [allowReply], the Reply button stays so the user can send another message.
/// iOS removed the notification when the reply was sent: the result is posted
/// quietly to Notification Center, and only alerts when [failed].
Future<void> showReplyStatus(
  fln.FlutterLocalNotificationsPlugin plugin, {
  required String pcId,
  required String sessionId,
  required ReplyNotif notif,
  required String body,
  bool allowReply = false,
  bool failed = false,
}) async {
  final details = fln.NotificationDetails(
    android: fln.AndroidNotificationDetails(
      kStopChannel.id,
      kStopChannel.name,
      channelDescription: kStopChannel.description,
      importance: kStopChannel.importance,
      priority: fln.Priority.defaultPriority,
      onlyAlertOnce: true,
      silent: true,
      subText: notif.pcName.isEmpty ? null : notif.pcName,
      showWhen: true,
      styleInformation: fln.BigTextStyleInformation(body),
      actions: allowReply ? <fln.AndroidNotificationAction>[replyAction()] : null,
    ),
    iOS: fln.DarwinNotificationDetails(
      subtitle: notif.pcName.isEmpty ? null : notif.pcName,
      threadIdentifier: sessionId,
      categoryIdentifier: allowReply ? DarwinCategory.reply : null,
      presentSound: failed,
      interruptionLevel: failed ? fln.InterruptionLevel.active : fln.InterruptionLevel.passive,
    ),
  );
  await plugin.show(
    id: notif.id,
    title: notif.title.isEmpty ? null : notif.title,
    body: body,
    notificationDetails: details,
    payload: EventPayload(
      pcId: pcId,
      sessionId: sessionId,
      eventId: notif.eventId,
      kind: EventKind.stop,
      title: notif.title,
      pcName: notif.pcName,
    ).encode(),
  );
}

/// Turns a Reply (typed into a `stop` notification) into a `send` message and
/// hands it to the task isolate: through its ReceivePort if the task runs,
/// else through the prefs queue. Returns false if [response] is not a Reply.
Future<bool> routeActionReply(fln.NotificationResponse response) async {
  if (response.actionId != kReplyActionId) return false;
  final p = EventPayload.tryParse(response.payload);
  if (p == null || p.sessionId.isEmpty) return false;
  final text = (response.input ?? '').trim();
  final notifId = response.id ?? 0;
  final notif = notifId == 0
      ? null
      : ReplyNotif(id: notifId, eventId: p.eventId, title: p.title, pcName: p.pcName);

  if (text.isEmpty) {
    // Clear Android's reply spinner.
    if (notif != null && !Platform.isIOS) {
      await _tryShowReplyStatus(p, notif, 'Nothing sent — the message was empty.', true);
    }
    return true;
  }

  final msg = sendCmd(p.pcId, p.sessionId, text, newClientId(), notif: notif);
  final port = IsolateNameServer.lookupPortByName(kAnswerPortName);
  if (port != null) {
    port.send(jsonEncode(msg));
    return true;
  }
  try {
    await Store.queueSend(msg);
  } catch (e) {
    debugPrint('mewo: queueing message failed: $e');
  }
  if (notif != null) {
    final when = Platform.isIOS ? 'you open Mewo on Fire' : 'Mewo on Fire reconnects';
    await _tryShowReplyStatus(p, notif, 'Waiting to send: $text\n(sent when $when)', false);
  }
  return true;
}

Future<void> _tryShowReplyStatus(EventPayload p, ReplyNotif notif, String body, bool allowReply) async {
  try {
    await showReplyStatus(
      fln.FlutterLocalNotificationsPlugin(),
      pcId: p.pcId,
      sessionId: p.sessionId,
      notif: notif,
      body: body,
      allowReply: allowReply,
    );
  } catch (e) {
    debugPrint('mewo: updating the reply notification failed: $e');
  }
}
