import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import 'theme/ember.dart';
import 'theme/glass.dart';

/// v3.7: Claude's questions in plain Arabic, the same panel as the Mewo
/// Session window's translate button. The PC translates them (a one-shot
/// Claude Code, Haiku): each question in simple Arabic, what it really asks,
/// every option's label and description in Arabic with its English label,
/// the option to pick ("الأفضل") and why. An option tapped here is picked in
/// the answer screen; nothing is sent from here.

/// One request's translation: loading, failed, or the questions.
class _Tr {
  const _Tr({this.loading = false, this.error = '', this.questions = const <Map<String, dynamic>>[]});
  final bool loading;
  final String error;
  final List<Map<String, dynamic>> questions;
}

/// The translations, asked of the PC once per request (again after a failure).
class _Translations {
  static final Map<String, ValueNotifier<_Tr>> _byKey = <String, ValueNotifier<_Tr>>{};

  static ValueNotifier<_Tr> of(PendingRequest e) {
    final known = _byKey[e.key];
    if (known != null) {
      if (known.value.error.isNotEmpty) ask(e, known);
      return known;
    }
    final n = ValueNotifier<_Tr>(const _Tr(loading: true));
    _byKey[e.key] = n;
    ask(e, n);
    return n;
  }

  static Future<void> ask(PendingRequest e, ValueNotifier<_Tr> n) async {
    n.value = const _Tr(loading: true);
    final qs = <Map<String, dynamic>>[
      for (final q in e.request.questions)
        {
          'header': q.header,
          'question': q.question,
          'multiSelect': q.multiSelect,
          'options': [
            for (final o in q.options) {'label': o.label, 'description': o.description},
          ],
        },
    ];
    final r = await AppState.instance.policy(e.pcId, 'translate', {'questions': qs}, timeout: const Duration(seconds: 130));
    final got = r['questions'];
    if (r['ok'] == true && got is List && got.length == qs.length) {
      n.value = _Tr(questions: [for (final q in got) q is Map ? Map<String, dynamic>.from(q) : <String, dynamic>{}]);
    } else {
      final why = r['error'];
      n.value = _Tr(error: why is String && why.isNotEmpty ? why : 'The translation did not come back.');
    }
  }
}

/// Opens the panel for [entry]'s questions. [isPicked], [onPick] and
/// [answered] tie its options to the answer screen's; [enabled] is false
/// once the answer is on its way.
Future<void> showArabicQuestions(
  BuildContext context, {
  required PendingRequest entry,
  required bool Function(int question, int option) isPicked,
  required void Function(int question, int option) onPick,
  required int Function() answered,
  required bool Function() enabled,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ArabicSheet(
      entry: entry,
      isPicked: isPicked,
      onPick: onPick,
      answered: answered,
      enabled: enabled,
    ),
  );
}

class _ArabicSheet extends StatefulWidget {
  const _ArabicSheet({
    required this.entry,
    required this.isPicked,
    required this.onPick,
    required this.answered,
    required this.enabled,
  });

  final PendingRequest entry;
  final bool Function(int, int) isPicked;
  final void Function(int, int) onPick;
  final int Function() answered;
  final bool Function() enabled;

  @override
  State<_ArabicSheet> createState() => _ArabicSheetState();
}

class _ArabicSheetState extends State<_ArabicSheet> {
  late final ValueNotifier<_Tr> _tr = _Translations.of(widget.entry);

  void _pick(int qi, int oi) {
    if (!widget.enabled()) return;
    HapticFeedback.selectionClick();
    widget.onPick(qi, oi);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final qs = widget.entry.request.questions;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 20, 8),
              child: Row(
                children: [
                  const IconTile(icon: Icons.translate_rounded, color: Ember.mewoSoft, size: 34, iconSize: 18),
                  const SizedBox(width: 12),
                  Expanded(child: Text('الأسئلة بالعربية', style: t.titleMedium)),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded, color: Ember.text2),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ValueListenableBuilder<_Tr>(
                valueListenable: _tr,
                builder: (context, tr, _) {
                  if (tr.loading) return _waiting(context);
                  if (tr.error.isNotEmpty) return _failed(context, tr.error);
                  return ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    children: [
                      for (var qi = 0; qi < qs.length; qi++) ...[
                        if (qi > 0) const Divider(height: 1),
                        _question(context, qi, qs[qi], qi < tr.questions.length ? tr.questions[qi] : const <String, dynamic>{}),
                      ],
                    ],
                  );
                },
              ),
            ),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Row(
                  children: [
                    EmberButton(label: 'تم', onPressed: () => Navigator.of(context).maybePop()),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'تمت الإجابة عن ${widget.answered()} من ${qs.length}',
                        style: t.bodySmall?.copyWith(color: Ember.text3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waiting(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      child: Row(
        children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Ember.mewoSoft)),
          const SizedBox(width: 12),
          Text('جارٍ الترجمة…', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Ember.text2)),
        ],
      ),
    );
  }

  Widget _failed(BuildContext context, String why) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('تعذّرت الترجمة.', style: t.bodyMedium?.copyWith(color: Ember.danger))),
              EmberButton(
                label: 'حاول مرة أخرى',
                small: true,
                style: EmberButtonStyle.secondary,
                onPressed: () => _Translations.ask(widget.entry, _tr),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(why, textDirection: TextDirection.ltr, style: t.bodySmall?.copyWith(color: Ember.text3)),
        ],
      ),
    );
  }

  Widget _question(BuildContext context, int qi, RequestQuestion q, Map<String, dynamic> a) {
    final t = Theme.of(context).textTheme;
    String s(Object? v) => v is String ? v : '';
    final b = a['best'];
    final best = <int>{
      if (b is List)
        for (final x in b)
          if (x is num) x.toInt(),
      if (b is num) b.toInt(),
    };
    final aOptions = a['options'] is List ? a['options'] as List : const <Object?>[];
    final question = s(a['question']).isNotEmpty ? s(a['question']) : q.question;
    final explain = s(a['explain']);
    final why = s(a['why']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: Ember.surface3, shape: BoxShape.circle),
                child: Text('${qi + 1}', style: t.labelSmall?.copyWith(color: Ember.text2)),
              ),
              if (q.header.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: Ember.surface3, borderRadius: BorderRadius.circular(5)),
                  child: Text(q.header, textDirection: TextDirection.ltr, style: t.labelSmall?.copyWith(color: Ember.text2)),
                ),
              if (q.multiSelect) Text('يمكنك اختيار أكثر من خيار', style: t.bodySmall?.copyWith(color: Ember.text3)),
            ],
          ),
          const SizedBox(height: 8),
          Text(question, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.6)),
          if (explain.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(explain, style: t.bodySmall?.copyWith(color: Ember.text2, height: 1.7)),
            ),
          const SizedBox(height: 10),
          for (var oi = 0; oi < q.options.length; oi++)
            _option(
              context,
              q,
              qi,
              oi,
              oi < aOptions.length && aOptions[oi] is Map ? Map<String, dynamic>.from(aOptions[oi] as Map) : const <String, dynamic>{},
              best.contains(oi),
            ),
          if (why.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(color: Ember.ok.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: 'الاقتراح: ', style: TextStyle(color: Ember.ok, fontWeight: FontWeight.w600)),
                  TextSpan(text: why),
                ]),
                style: t.bodySmall?.copyWith(color: Ember.text2, height: 1.7),
              ),
            ),
        ],
      ),
    );
  }

  Widget _option(BuildContext context, RequestQuestion q, int qi, int oi, Map<String, dynamic> ao, bool best) {
    final t = Theme.of(context).textTheme;
    final o = q.options[oi];
    final picked = widget.isPicked(qi, oi);
    final label = ao['label'] is String && (ao['label'] as String).isNotEmpty ? ao['label'] as String : o.label;
    final desc = ao['description'] is String && (ao['description'] as String).isNotEmpty ? ao['description'] as String : o.description;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: picked ? Ember.flame.withValues(alpha: 0.12) : Ember.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: picked ? Ember.flame.withValues(alpha: 0.7) : Ember.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _pick(qi, oi),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    gradient: picked ? Ember.fire : null,
                    shape: q.multiSelect ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius: q.multiSelect ? BorderRadius.circular(6) : null,
                    border: Border.all(color: picked ? Colors.transparent : Ember.text3, width: 1.5),
                  ),
                  child: picked ? const Icon(Icons.check_rounded, size: 14, color: Ember.bg) : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(label, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                          if (best)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                              decoration: BoxDecoration(color: Ember.ok.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(5)),
                              child: Text('الأفضل', style: t.labelSmall?.copyWith(color: Ember.ok, fontWeight: FontWeight.w600)),
                            ),
                        ],
                      ),
                      if (label != o.label)
                        Text(o.label, textDirection: TextDirection.ltr, style: t.labelSmall?.copyWith(color: Ember.text3)),
                      if (desc.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(desc, style: t.bodySmall?.copyWith(color: Ember.text2, height: 1.7)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
