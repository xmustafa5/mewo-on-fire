import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../requests.dart';
import 'history_tab.dart' show relativeTime;
import 'keyboard_hide_button.dart';

/// Answers one pending request (permission prompt, question or plan approval).
/// Opened from the "Waiting for you" list or by tapping a request notification.
class AnswerScreen extends StatefulWidget {
  const AnswerScreen({super.key, required this.pcId, required this.requestId});

  final String pcId;
  final String requestId;

  static const String _routePrefix = '/answer/';

  static Route<void> route(String pcId, String requestId) => MaterialPageRoute<void>(
        settings: RouteSettings(name: '$_routePrefix${requestKey(pcId, requestId)}'),
        builder: (_) => AnswerScreen(pcId: pcId, requestId: requestId),
      );

  static bool isAnswerRoute(Route<dynamic> r) => r.settings.name?.startsWith(_routePrefix) ?? false;

  static IconData iconFor(String kind) {
    switch (kind) {
      case RequestKind.question:
        return Icons.help_outline;
      case RequestKind.plan:
        return Icons.assignment_outlined;
      default:
        return Icons.lock_outline;
    }
  }

  static String kindLabel(String kind) {
    switch (kind) {
      case RequestKind.question:
        return 'Question';
      case RequestKind.plan:
        return 'Plan approval';
      default:
        return 'Permission';
    }
  }

  @override
  State<AnswerScreen> createState() => _AnswerScreenState();
}

class _AnswerScreenState extends State<AnswerScreen> {
  static const int _otherIndex = -1; // "Other…" choice

  final AppState _state = AppState.instance;
  final TextEditingController _message = TextEditingController();

  // Question answers by question index.
  final Map<int, int> _single = <int, int>{};
  final Map<int, Set<int>> _multi = <int, Set<int>>{};
  final Map<int, TextEditingController> _other = <int, TextEditingController>{};

  PendingRequest? _entry;
  bool _submitting = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _entry = _state.findRequest(widget.pcId, widget.requestId);
    _state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    _message.dispose();
    for (final c in _other.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _otherCtrl(int i) => _other.putIfAbsent(i, TextEditingController.new);

  void _onStateChanged() {
    if (!mounted || _closing) return;
    final e = _state.findRequest(widget.pcId, widget.requestId);
    if (e != null) {
      setState(() => _entry = e);
      return;
    }
    if (_entry == null || _submitting) return;
    // Resolved while open.
    _closing = true;
    final by = _state.resolvedBy[requestKey(widget.pcId, widget.requestId)] ?? '';
    final text = by == 'phone'
        ? 'Answered from a phone'
        : by == 'timeout'
            ? 'The request expired'
            : 'Answered on the PC';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    Navigator.of(context).maybePop();
  }

  Future<void> _submit(Map<String, dynamic> answer) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final pcName = _entry?.pcName ?? 'the PC';
    await _state.answer(widget.pcId, widget.requestId, answer);
    if (!mounted) return;
    _closing = true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Answer sent to $pcName')));
    Navigator.of(context).maybePop();
  }

  /// `{"<question text>": "<answer>"}` or null while a question is unanswered.
  Map<String, String>? _questionAnswers(CcRequest r) {
    if (r.questions.isEmpty) return null;
    final out = <String, String>{};
    for (var i = 0; i < r.questions.length; i++) {
      final q = r.questions[i];
      final other = _other[i]?.text.trim() ?? '';
      if (q.multiSelect) {
        final sel = _multi[i] ?? const <int>{};
        final labels = <String>[
          for (var j = 0; j < q.options.length; j++)
            if (sel.contains(j)) q.options[j].label,
          if (sel.contains(_otherIndex) && other.isNotEmpty) other,
        ];
        if (labels.isEmpty) return null;
        out[q.question] = labels.join(', ');
      } else {
        final s = _single[i];
        if (s == null) return null;
        if (s == _otherIndex) {
          if (other.isEmpty) return null;
          out[q.question] = other;
        } else if (s >= 0 && s < q.options.length) {
          out[q.question] = q.options[s].label;
        } else {
          return null;
        }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final e = _entry;
    return Scaffold(
      appBar: AppBar(
        title: Text(e == null ? 'Request' : AnswerScreen.kindLabel(e.request.kind)),
        actions: const [KeyboardHideButton()],
      ),
      body: e == null ? _gone(context) : _body(context, e),
    );
  }

  Widget _gone(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 56, color: cs.outline),
            const SizedBox(height: 16),
            Text(
              'Claude is no longer waiting for this.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PendingRequest e) {
    final r = e.request;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final locked = _submitting || e.answered;
    final isQuestion = r.kind == RequestKind.question;
    return Column(
      children: [
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              _Header(entry: e),
              const SizedBox(height: 16),
              Text(r.title.isEmpty ? AnswerScreen.kindLabel(r.kind) : r.title, style: t.titleLarge),
              if (r.kind == RequestKind.permission && r.tool.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Tool: ${r.tool}', style: t.bodySmall?.copyWith(color: cs.outline)),
                ),
              const SizedBox(height: 12),
              if (e.answered) ...[
                const _Banner(text: 'Answer sent — waiting for the PC to confirm.'),
                const SizedBox(height: 12),
              ],
              if (isQuestion && r.questions.isNotEmpty)
                ..._questions(context, r, locked)
              else
                _DetailBox(
                  text: r.detail.isNotEmpty ? r.detail : r.summary,
                  monospace: !isQuestion,
                ),
              if (!isQuestion) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _message,
                  enabled: !locked,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: r.kind == RequestKind.plan
                        ? 'Feedback for Claude (optional)'
                        : 'Reason for Claude (optional)',
                    helperText: r.kind == RequestKind.plan
                        ? 'Sent when you reject the plan.'
                        : 'Sent when you deny.',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: _buttons(context, r, locked),
          ),
        ),
      ],
    );
  }

  Widget _buttons(BuildContext context, CcRequest r, bool locked) {
    final cs = Theme.of(context).colorScheme;
    final denyStyle = OutlinedButton.styleFrom(foregroundColor: cs.error);
    switch (r.kind) {
      case RequestKind.question:
        if (r.questions.isEmpty) {
          return Text(
            'This question can only be answered on the PC.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.outline),
          );
        }
        final answers = _questionAnswers(r);
        return SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: locked || answers == null ? null : () => _submit(Answers.questions(answers)),
            child: const Text('Submit'),
          ),
        );
      case RequestKind.plan:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: denyStyle,
                onPressed: locked ? null : () => _submit(Answers.reject(_message.text)),
                child: const Text('Reject'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: locked ? null : () => _submit(Answers.approve()),
                child: const Text('Approve'),
              ),
            ),
          ],
        );
      default: // permission
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: denyStyle,
                onPressed: locked ? null : () => _submit(Answers.deny(_message.text)),
                child: const Text('Deny'),
              ),
            ),
            if (r.canAllowAlways) ...[
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: locked ? null : () => _submit(Answers.allowAlways()),
                  child: const Text('Always'),
                ),
              ),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: locked ? null : () => _submit(Answers.allow()),
                child: const Text('Allow'),
              ),
            ),
          ],
        );
    }
  }

  List<Widget> _questions(BuildContext context, CcRequest r, bool locked) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final out = <Widget>[];
    for (var i = 0; i < r.questions.length; i++) {
      final q = r.questions[i];
      if (i > 0) out.add(const Divider(height: 32));
      if (q.header.isNotEmpty) {
        out.add(Text(q.header, style: t.labelLarge?.copyWith(color: cs.primary)));
      }
      out.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Text(q.question, style: t.titleMedium),
      ));
      if (q.multiSelect) {
        out.add(Text('Select all that apply', style: t.bodySmall?.copyWith(color: cs.outline)));
      }
      out.add(q.multiSelect ? _multiSelect(i, q, locked) : _singleSelect(i, q, locked));
    }
    return out;
  }

  Widget _singleSelect(int i, RequestQuestion q, bool locked) {
    return RadioGroup<int>(
      groupValue: _single[i],
      onChanged: (int? v) {
        if (locked || v == null) return;
        setState(() => _single[i] = v);
      },
      child: Column(
        children: [
          for (var j = 0; j < q.options.length; j++)
            RadioListTile<int>(
              value: j,
              enabled: !locked,
              contentPadding: EdgeInsets.zero,
              title: Text(q.options[j].label),
              subtitle: q.options[j].description.isEmpty ? null : Text(q.options[j].description),
            ),
          RadioListTile<int>(
            value: _otherIndex,
            enabled: !locked,
            contentPadding: EdgeInsets.zero,
            title: const Text('Other…'),
          ),
          if (_single[i] == _otherIndex) _otherField(i, locked),
        ],
      ),
    );
  }

  Widget _multiSelect(int i, RequestQuestion q, bool locked) {
    final sel = _multi.putIfAbsent(i, () => <int>{});
    void toggle(int j, bool? v) {
      setState(() {
        if (v == true) {
          sel.add(j);
        } else {
          sel.remove(j);
        }
      });
    }

    return Column(
      children: [
        for (var j = 0; j < q.options.length; j++)
          CheckboxListTile(
            value: sel.contains(j),
            onChanged: locked ? null : (v) => toggle(j, v),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Text(q.options[j].label),
            subtitle: q.options[j].description.isEmpty ? null : Text(q.options[j].description),
          ),
        CheckboxListTile(
          value: sel.contains(_otherIndex),
          onChanged: locked ? null : (v) => toggle(_otherIndex, v),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text('Other…'),
        ),
        if (sel.contains(_otherIndex)) _otherField(i, locked),
      ],
    );
  }

  Widget _otherField(int i, bool locked) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 0, 8),
        child: TextField(
          controller: _otherCtrl(i),
          enabled: !locked,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Type your answer',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header({required this.entry});
  final PendingRequest entry;

  @override
  Widget build(BuildContext context) {
    final r = entry.request;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          backgroundColor: cs.primaryContainer,
          foregroundColor: cs.onPrimaryContainer,
          child: Icon(AnswerScreen.iconFor(r.kind)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.project.isEmpty ? '(unknown project)' : r.project,
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                '${entry.pcName} · ${relativeTime(r.time)}',
                style: t.bodySmall?.copyWith(color: cs.outline),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailBox extends StatelessWidget {
  const _DetailBox({required this.text, required this.monospace});
  final String text;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text.isEmpty ? '(no details)' : text,
        style: monospace
            ? const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35)
            : Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule_send_outlined, color: cs.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(color: cs.onSecondaryContainer))),
        ],
      ),
    );
  }
}
