import 'dart:async';
import 'dart:convert';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;

import 'models.dart';
import 'sessions.dart' show kReplyActionId, routeActionReply;
import 'storage.dart';

/// Answering prompts from the phone (PROTOCOL.md v1.1): answer bodies, the
/// request notification's buttons + payload, and the action-button handler.
///
/// Routing of answers to the task isolate (the only owner of PC connections):
/// - UI isolate → `FlutterForegroundTask.sendDataToTask({"cmd":"answer",...})`
///   (see `AppState.answer`), or the queue when the service is not running.
/// - Action buttons → [onNotificationResponseBackground] in the plugin's own
///   background isolate → the task's ReceivePort registered under
///   [kAnswerPortName], or the queue (`queued_answer_*`, see `Store`) when the
///   task is not running.

/// Name of the task isolate's ReceivePort for answers (IsolateNameServer).
/// Also carries v1.2 `send` messages (Reply action, see `sessions.dart`).
const String kAnswerPortName = 'ccnotify_answers';

/// flutter_local_notifications settings, shared by the UI and task isolates.
final fln.InitializationSettings kNotificationInitSettings = fln.InitializationSettings(
  android: const fln.AndroidInitializationSettings('ic_stat_notify'),
  iOS: fln.DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
    notificationCategories: _darwinCategories(),
  ),
);

/// iOS notification categories. Unlike Android actions, the buttons of an
/// iOS notification are a fixed set registered up front, selected per
/// notification by its category.
class DarwinCategory {
  static const permission = 'ccn_permission';
  static const permissionAlways = 'ccn_permission_always';
  static const plan = 'ccn_plan';

  /// `stop` notifications: Reply with inline text input.
  static const reply = 'ccn_reply';
}

/// The iOS category with [r]'s buttons. Null for a question: its option
/// labels differ per request, so it is answered in the app (tap the
/// notification).
String? darwinRequestCategory(CcRequest r) {
  switch (r.kind) {
    case RequestKind.plan:
      return DarwinCategory.plan;
    case RequestKind.question:
      return null;
    default:
      return r.canAllowAlways ? DarwinCategory.permissionAlways : DarwinCategory.permission;
  }
}

/// Same action ids as the Android buttons (see [requestActions]), handled by
/// [onNotificationResponseBackground] without opening the app. Everything
/// that lets Claude Code go on needs the phone unlocked.
List<fln.DarwinNotificationCategory> _darwinCategories() {
  const unlock = <fln.DarwinNotificationActionOption>{
    fln.DarwinNotificationActionOption.authenticationRequired,
  };
  const destructive = <fln.DarwinNotificationActionOption>{
    fln.DarwinNotificationActionOption.destructive,
  };
  final allow = fln.DarwinNotificationAction.plain(RequestAction.allow, 'Allow', options: unlock);
  final always =
      fln.DarwinNotificationAction.plain(RequestAction.allowAlways, 'Always allow', options: unlock);
  final deny = fln.DarwinNotificationAction.plain(RequestAction.deny, 'Deny', options: destructive);
  return <fln.DarwinNotificationCategory>[
    fln.DarwinNotificationCategory(DarwinCategory.permission, actions: [allow, deny]),
    fln.DarwinNotificationCategory(DarwinCategory.permissionAlways, actions: [allow, always, deny]),
    fln.DarwinNotificationCategory(DarwinCategory.plan, actions: [
      fln.DarwinNotificationAction.plain(RequestAction.approve, 'Approve', options: unlock),
      fln.DarwinNotificationAction.plain(RequestAction.reject, 'Reject', options: destructive),
    ]),
    fln.DarwinNotificationCategory(DarwinCategory.reply, actions: [
      fln.DarwinNotificationAction.text(
        kReplyActionId,
        'Reply',
        buttonTitle: 'Send',
        placeholder: 'Message to Claude',
        options: unlock,
      ),
    ]),
  ];
}

/// Action ids of request notification buttons.
class RequestAction {
  static const allow = 'allow';
  static const allowAlways = 'allow_always';
  static const deny = 'deny';
  static const approve = 'approve';
  static const reject = 'reject';

  /// `opt_<index>`: option of the single quick question.
  static const optionPrefix = 'opt_';
}

/// Answer bodies (PROTOCOL.md v1.1 "Answer").
class Answers {
  static Map<String, dynamic> allow() => {'action': 'allow'};

  static Map<String, dynamic> allowAlways() => {'action': 'allow_always'};

  /// An empty [message] is left out, so the PC uses its default text.
  static Map<String, dynamic> deny([String message = '']) => {
        'action': 'deny',
        if (message.trim().isNotEmpty) 'message': message.trim(),
      };

  static Map<String, dynamic> approve() => {'action': 'approve'};

  /// An empty [message] is left out, so the PC uses its default text.
  static Map<String, dynamic> reject([String message = '']) => {
        'action': 'reject',
        if (message.trim().isNotEmpty) 'message': message.trim(),
      };

  /// `{"<question text>": "<label(s) or typed text>"}`.
  static Map<String, dynamic> questions(Map<String, String> answers) => {'answers': answers};
}

/// Message understood by the task isolate (port, sendDataToTask and queue).
Map<String, dynamic> answerMessage(String pcId, String requestId, Map<String, dynamic> answer) =>
    {'cmd': 'answer', 'pc_id': pcId, 'request_id': requestId, 'answer': answer};

/// The question that can be answered with notification buttons: exactly one
/// single-select question with 1–3 options.
RequestQuestion? quickQuestion(CcRequest r) {
  if (r.kind != RequestKind.question || r.questions.length != 1) return null;
  final q = r.questions.first;
  if (q.multiSelect || q.options.isEmpty || q.options.length > 3) return null;
  return q;
}

/// (action id, button label) of the buttons on [r]'s notification.
List<(String, String)> requestActions(CcRequest r) {
  switch (r.kind) {
    case RequestKind.plan:
      return const [(RequestAction.approve, 'Approve'), (RequestAction.reject, 'Reject')];
    case RequestKind.question:
      final q = quickQuestion(r);
      if (q == null) return const <(String, String)>[];
      return [
        for (var i = 0; i < q.options.length; i++)
          ('${RequestAction.optionPrefix}$i', q.options[i].label),
      ];
    default: // permission
      return [
        (RequestAction.allow, 'Allow'),
        if (r.canAllowAlways) (RequestAction.allowAlways, 'Always'),
        (RequestAction.deny, 'Deny'),
      ];
  }
}

/// Payload of a request notification. Carries what an action button needs to
/// build the answer, so the background handler doesn't have to load anything.
class RequestPayload {
  const RequestPayload({
    required this.pcId,
    required this.requestId,
    this.question = '',
    this.labels = const <String>[],
  });

  final String pcId;
  final String requestId;
  final String question; // quick question text (kind question only)
  final List<String> labels; // its option labels, by button index

  static const _type = 'request';

  factory RequestPayload.forRequest(String pcId, CcRequest r) {
    final q = quickQuestion(r);
    return RequestPayload(
      pcId: pcId,
      requestId: r.id,
      question: q?.question ?? '',
      labels: q == null ? const <String>[] : [for (final o in q.options) o.label],
    );
  }

  String encode() => jsonEncode({
        'type': _type,
        'pc_id': pcId,
        'request_id': requestId,
        if (question.isNotEmpty) 'question': question,
        if (labels.isNotEmpty) 'labels': labels,
      });

  /// Null for other notifications (event notifications carry the plain pc id).
  static RequestPayload? tryParse(String? raw) {
    if (raw == null || !raw.startsWith('{')) return null;
    try {
      final d = jsonDecode(raw);
      if (d is! Map || d['type'] != _type) return null;
      final pcId = d['pc_id'];
      final id = d['request_id'];
      if (pcId is! String || id is! String || pcId.isEmpty || id.isEmpty) return null;
      final q = d['question'];
      final labels = d['labels'];
      return RequestPayload(
        pcId: pcId,
        requestId: id,
        question: q is String ? q : '',
        labels: labels is List ? labels.map((e) => '$e').toList() : const <String>[],
      );
    } catch (_) {
      return null;
    }
  }

  /// The answer for a tapped button, or null for an unknown [actionId].
  Map<String, dynamic>? answerFor(String actionId) {
    switch (actionId) {
      case RequestAction.allow:
        return Answers.allow();
      case RequestAction.allowAlways:
        return Answers.allowAlways();
      case RequestAction.deny:
        return Answers.deny();
      case RequestAction.approve:
        return Answers.approve();
      case RequestAction.reject:
        return Answers.reject();
    }
    if (actionId.startsWith(RequestAction.optionPrefix) && question.isNotEmpty) {
      final i = int.tryParse(actionId.substring(RequestAction.optionPrefix.length));
      if (i != null && i >= 0 && i < labels.length) {
        return Answers.questions({question: labels[i]});
      }
    }
    return null;
  }
}

/// Action-button handler, registered with `initialize()` in both the UI and
/// the task isolate. On Android, every action with `showsUserInterface: false`
/// goes through the plugin's ActionBroadcastReceiver, which runs this in a
/// separate background engine/isolate — also while the app is open.
@pragma('vm:entry-point')
void onNotificationResponseBackground(fln.NotificationResponse response) {
  unawaited(_routeAction(response));
}

Future<void> _routeAction(fln.NotificationResponse response) async {
  if (await routeActionReply(response)) return; // v1.2 Reply on a stop notification
  await routeActionAnswer(response);
}

/// Turns an action tap into an answer and hands it to the task isolate:
/// through its ReceivePort if the task runs, else through the prefs queue.
/// Returns false if [response] is not a request button.
Future<bool> routeActionAnswer(fln.NotificationResponse response) async {
  final actionId = response.actionId;
  if (actionId == null || actionId.isEmpty) return false;
  final p = RequestPayload.tryParse(response.payload);
  if (p == null) return false;
  final answer = p.answerFor(actionId);
  if (answer == null) return false;

  final port = IsolateNameServer.lookupPortByName(kAnswerPortName);
  if (port != null) {
    port.send(jsonEncode(answerMessage(p.pcId, p.requestId, answer)));
    return true;
  }
  try {
    await Store.queueAnswer(p.pcId, p.requestId, answer);
  } catch (e) {
    debugPrint('ccnotify: queueing answer failed: $e');
  }
  return true;
}
