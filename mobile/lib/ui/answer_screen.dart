import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../app_state.dart';
import '../models.dart';
import '../requests.dart';
import 'history_tab.dart' show relativeTime;
import 'keyboard_hide_button.dart';
import 'theme/ember.dart';
import 'theme/flame.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

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
        return Icons.help_outline_rounded;
      case RequestKind.plan:
        return Icons.assignment_outlined;
      default:
        return Icons.lock_outline_rounded;
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

  /// What was just sent, shown big for a moment before the screen closes.
  String? _sentLabel;

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

  Future<void> _submit(Map<String, dynamic> answer, String label) async {
    if (_submitting) return;
    HapticFeedback.mediumImpact();
    setState(() => _submitting = true);
    await _state.answer(widget.pcId, widget.requestId, answer);
    if (!mounted) return;
    _closing = true;
    setState(() => _sentLabel = label);
    HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!mounted) return;
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
    final color = e == null ? Ember.text2 : Ember.requestColor(e.request.kind);
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: GlassTopBar(
        title: Text(e == null ? 'Request' : AnswerScreen.kindLabel(e.request.kind)),
        subtitle: e == null ? null : Text(e.pcName),
        actions: const [KeyboardHideButton()],
      ),
      body: EmberBackground(
        animate: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Built under the Scaffold's body, where the top inset includes the bar.
            e == null ? _gone(context) : Builder(builder: (context) => _body(context, e)),
            if (_sentLabel != null) _SentOverlay(label: _sentLabel!, color: color, pcName: e?.pcName ?? 'the PC'),
          ],
        ),
      ),
    );
  }

  Widget _gone(BuildContext context) {
    return Center(
      child: EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'Claude is no longer waiting for this',
        body: 'It was answered elsewhere or the request expired.',
        action: EmberButton(
          label: 'Close',
          style: EmberButtonStyle.secondary,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PendingRequest e) {
    final r = e.request;
    final t = Theme.of(context).textTheme;
    final locked = _submitting || e.answered;
    final isQuestion = r.kind == RequestKind.question;
    final topInset = MediaQuery.paddingOf(context).top;
    var n = 0;
    Widget enter(Widget child) => FadeSlideIn(delay: Motion.stagger(n++, step: 60), child: child);
    return Column(
      children: [
        Expanded(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, topInset + 16, 20, 24),
            children: [
              enter(_Header(entry: e)),
              const SizedBox(height: 20),
              enter(Text(r.title.isEmpty ? AnswerScreen.kindLabel(r.kind) : r.title, style: t.headlineSmall)),
              if (r.kind == RequestKind.permission && r.tool.isNotEmpty)
                enter(Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(9, 4, 10, 4),
                      decoration: BoxDecoration(
                        color: Ember.surface2,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Ember.line),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.terminal_rounded, size: 13, color: Ember.text3),
                          const SizedBox(width: 6),
                          Text(
                            r.tool,
                            style: t.labelMedium?.copyWith(color: Ember.text2, fontFamily: Ember.mono(context)),
                          ),
                        ],
                      ),
                    ),
                  ),
                )),
              const SizedBox(height: 16),
              if (e.answered) ...[
                enter(const _Banner(text: 'Answer sent — waiting for the PC to confirm.')),
                const SizedBox(height: 14),
              ],
              if (isQuestion && r.questions.isNotEmpty)
                ..._questions(context, r, locked, enter)
              else
                enter(_Detail(request: r)),
              if (!isQuestion) ...[
                const SizedBox(height: 18),
                enter(TextField(
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
                  ),
                )),
              ],
            ],
          ),
        ),
        GlassBar(
          border: const Border(top: BorderSide(color: Ember.line)),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: _buttons(context, r, locked),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buttons(BuildContext context, CcRequest r, bool locked) {
    switch (r.kind) {
      case RequestKind.question:
        if (r.questions.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'This question can only be answered on the PC.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Ember.text3),
            ),
          );
        }
        final answers = _questionAnswers(r);
        return EmberButton(
          label: 'Send answer',
          icon: Icons.arrow_upward_rounded,
          expand: true,
          shimmer: true,
          busy: _submitting,
          onPressed: locked || answers == null ? null : () => _submit(Answers.questions(answers), 'Answer sent'),
        );
      case RequestKind.plan:
        return Row(
          children: [
            Expanded(
              child: EmberButton(
                label: 'Reject',
                icon: Icons.close_rounded,
                style: EmberButtonStyle.danger,
                onPressed: locked ? null : () => _submit(Answers.reject(_message.text), 'Rejected'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: EmberButton(
                label: 'Approve plan',
                icon: Icons.check_rounded,
                shimmer: true,
                busy: _submitting,
                onPressed: locked ? null : () => _submit(Answers.approve(), 'Approved'),
              ),
            ),
          ],
        );
      default: // permission
        return Row(
          children: [
            Expanded(
              child: EmberButton(
                label: 'Deny',
                style: EmberButtonStyle.danger,
                onPressed: locked ? null : () => _submit(Answers.deny(_message.text), 'Denied'),
              ),
            ),
            if (r.canAllowAlways) ...[
              const SizedBox(width: 10),
              Expanded(
                child: EmberButton(
                  label: 'Always',
                  style: EmberButtonStyle.secondary,
                  onPressed: locked ? null : () => _submit(Answers.allowAlways(), 'Always allowed'),
                ),
              ),
            ],
            const SizedBox(width: 10),
            Expanded(
              flex: r.canAllowAlways ? 1 : 2,
              child: EmberButton(
                label: 'Allow',
                icon: Icons.check_rounded,
                shimmer: true,
                busy: _submitting,
                onPressed: locked ? null : () => _submit(Answers.allow(), 'Allowed'),
              ),
            ),
          ],
        );
    }
  }

  List<Widget> _questions(BuildContext context, CcRequest r, bool locked, Widget Function(Widget) enter) {
    final t = Theme.of(context).textTheme;
    final out = <Widget>[];
    for (var i = 0; i < r.questions.length; i++) {
      final q = r.questions[i];
      if (i > 0) out.add(const Padding(padding: EdgeInsets.symmetric(vertical: 18), child: Divider()));
      if (q.header.isNotEmpty) {
        out.add(enter(Text(
          q.header.toUpperCase(),
          style: t.labelSmall?.copyWith(color: Ember.amber, letterSpacing: 1.2),
        )));
        out.add(const SizedBox(height: 6));
      }
      out.add(enter(Text(q.question, style: t.titleMedium)));
      out.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 12),
        child: Text(
          q.multiSelect ? 'Select all that apply' : 'Pick one',
          style: t.bodySmall?.copyWith(color: Ember.text3),
        ),
      ));
      out.add(enter(q.multiSelect ? _multiSelect(i, q, locked) : _singleSelect(i, q, locked)));
    }
    return out;
  }

  Widget _singleSelect(int i, RequestQuestion q, bool locked) {
    void pick(int v) {
      if (locked) return;
      HapticFeedback.selectionClick();
      setState(() => _single[i] = v);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var j = 0; j < q.options.length; j++)
          _OptionTile(
            label: q.options[j].label,
            description: q.options[j].description,
            selected: _single[i] == j,
            multi: false,
            enabled: !locked,
            onTap: () => pick(j),
          ),
        _OptionTile(
          label: 'Other…',
          description: '',
          selected: _single[i] == _otherIndex,
          multi: false,
          enabled: !locked,
          onTap: () => pick(_otherIndex),
        ),
        AnimatedSize(
          duration: Motion.base,
          curve: Motion.easeOut,
          alignment: Alignment.topCenter,
          child: _single[i] == _otherIndex ? _otherField(i, locked) : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _multiSelect(int i, RequestQuestion q, bool locked) {
    final sel = _multi.putIfAbsent(i, () => <int>{});
    void toggle(int j) {
      if (locked) return;
      HapticFeedback.selectionClick();
      setState(() {
        if (!sel.remove(j)) sel.add(j);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var j = 0; j < q.options.length; j++)
          _OptionTile(
            label: q.options[j].label,
            description: q.options[j].description,
            selected: sel.contains(j),
            multi: true,
            enabled: !locked,
            onTap: () => toggle(j),
          ),
        _OptionTile(
          label: 'Other…',
          description: '',
          selected: sel.contains(_otherIndex),
          multi: true,
          enabled: !locked,
          onTap: () => toggle(_otherIndex),
        ),
        AnimatedSize(
          duration: Motion.base,
          curve: Motion.easeOut,
          alignment: Alignment.topCenter,
          child: sel.contains(_otherIndex) ? _otherField(i, locked) : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _otherField(int i, bool locked) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
        child: TextField(
          controller: _otherCtrl(i),
          enabled: !locked,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(hintText: 'Type your answer'),
        ),
      );
}

/// One choice of a question: a glass tile that lights up when picked.
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.description,
    required this.selected,
    required this.multi,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool selected;
  final bool multi;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      selected: selected,
      enabled: enabled,
      button: true,
      label: label,
      child: PressScale(
        scale: 0.985,
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: Motion.base,
          curve: Motion.easeOut,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: selected ? Ember.flame.withValues(alpha: 0.12) : Ember.surface.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? Ember.flame.withValues(alpha: 0.7) : Ember.line),
            boxShadow: selected ? [BoxShadow(color: Ember.flame.withValues(alpha: 0.2), blurRadius: 18)] : const [],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: Motion.base,
                curve: Motion.emphasized,
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  gradient: selected ? Ember.fire : null,
                  color: selected ? null : Colors.transparent,
                  shape: multi ? BoxShape.rectangle : BoxShape.circle,
                  borderRadius: multi ? BorderRadius.circular(7) : null,
                  border: Border.all(color: selected ? Colors.transparent : Ember.text3, width: 1.5),
                ),
                child: AnimatedScale(
                  duration: Motion.base,
                  curve: Motion.spring,
                  scale: selected ? 1 : 0,
                  child: const Icon(Icons.check_rounded, size: 16, color: Ember.bg),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    if (description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(description, style: t.bodySmall?.copyWith(color: Ember.text2)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entry});
  final PendingRequest entry;

  @override
  Widget build(BuildContext context) {
    final r = entry.request;
    final t = Theme.of(context).textTheme;
    final color = Ember.requestColor(r.kind);
    return Row(
      children: [
        Hero(
          tag: 'request:${entry.key}',
          child: IconTile(icon: AnswerScreen.iconFor(r.kind), color: color, size: 54, iconSize: 26, glow: true),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.project.isEmpty ? 'unknown project' : r.project,
                style: t.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Text(
                '${entry.pcName} · ${relativeTime(r.time)}',
                style: t.bodySmall?.copyWith(color: Ember.text3),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What the request is about: the tool input for a permission, the plan as
/// Markdown for a plan approval.
class _Detail extends StatelessWidget {
  const _Detail({required this.request});
  final CcRequest request;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final text = r.detail.isNotEmpty ? r.detail : r.summary;
    if (r.kind == RequestKind.plan) {
      final theme = Theme.of(context);
      final t = theme.textTheme;
      return GlassCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: text.isEmpty
            ? Text('(no details)', style: t.bodyMedium?.copyWith(color: Ember.text3))
            : MarkdownBody(
                data: text,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: t.bodyMedium,
                  h1: t.titleLarge,
                  h2: t.titleMedium,
                  h3: t.titleSmall,
                  listBullet: t.bodyMedium?.copyWith(color: Ember.amber),
                  code: TextStyle(
                    fontFamily: Ember.mono(context),
                    fontSize: 13,
                    color: Ember.gold,
                    backgroundColor: Ember.codeBg,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: Ember.codeBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Ember.line),
                  ),
                  codeblockPadding: const EdgeInsets.all(12),
                  blockquoteDecoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: Ember.ember, width: 3)),
                  ),
                  horizontalRuleDecoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Ember.line)),
                  ),
                ),
              ),
      );
    }
    return CodeBox(
      text: text.isEmpty ? '(no details)' : text,
      label: r.tool.isNotEmpty ? r.tool : 'Details',
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      radius: 16,
      borderColor: Ember.amber.withValues(alpha: 0.4),
      fill: Ember.amber.withValues(alpha: 0.08),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Ember.amber),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Ember.text))),
        ],
      ),
    );
  }
}

/// Big check for a moment after an answer went out.
class _SentOverlay extends StatelessWidget {
  const _SentOverlay({required this.label, required this.color, required this.pcName});

  final String label;
  final Color color;
  final String pcName;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: Motion.slow,
          curve: Motion.easeOut,
          builder: (context, v, _) => ColoredBox(
            color: Ember.bg.withValues(alpha: 0.78 * v),
            child: Center(
              child: Transform.scale(
                scale: 0.6 + 0.4 * Motion.spring.transform(v),
                child: Opacity(
                  opacity: v,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 92,
                        height: 92,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: Ember.fire,
                          boxShadow: [BoxShadow(color: Ember.flame.withValues(alpha: 0.55), blurRadius: 40)],
                        ),
                        child: const Icon(Icons.check_rounded, size: 48, color: Ember.bg),
                      ),
                      const SizedBox(height: 20),
                      Text(label, style: t.headlineSmall),
                      const SizedBox(height: 4),
                      Text('Sent to $pcName', style: t.bodyMedium?.copyWith(color: Ember.text2)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
