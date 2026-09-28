import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../app_state.dart';
import '../models.dart';
import '../requests.dart' show Answers;
import 'answer_screen.dart';
import 'sessions_tab.dart' show SessionStateChip;

/// One session's chat (PROTOCOL.md v1.2): bubbles, tool one-liners, and an
/// input bar to continue the session from the phone. Opened from the Sessions
/// tab, a History item or by tapping an event notification. Pending v1.1
/// requests of the session (permission / question / plan) are pinned as cards
/// above the input bar, with quick answers.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.pcId, required this.sessionId});

  final String pcId;
  final String sessionId;

  static const String _routePrefix = '/chat/';

  static Route<void> route(String pcId, String sessionId) => MaterialPageRoute<void>(
        settings: RouteSettings(name: '$_routePrefix${sessionKey(pcId, sessionId)}'),
        builder: (_) => ChatScreen(pcId: pcId, sessionId: sessionId),
      );

  static bool isChatRoute(Route<dynamic> r) => r.settings.name?.startsWith(_routePrefix) ?? false;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final AppState _state = AppState.instance;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController(); // chat list (reversed)
  final ScrollController _cardsScroll = ScrollController(); // request cards

  /// Expanded tool groups / tool lines, by row id.
  final Set<String> _expanded = <String>{};
  bool _canSend = false;

  /// Request cards shown at the last update: key → answered from this phone.
  Map<String, bool> _cards = <String, bool>{};

  /// Requests answered from a card here, shown as "Sending…" until resolved.
  final Set<String> _sent = <String>{};

  MarkdownStyleSheet? _md;
  ThemeData? _mdTheme;

  @override
  void initState() {
    super.initState();
    _cards = <String, bool>{for (final r in _pendingRequests()) r.key: r.answered};
    if (_cards.isNotEmpty) _scrollToBottomSoon();
    _state.addListener(_onStateChanged);
    _input.addListener(_onInputChanged);
    _state.watchChat(widget.pcId, widget.sessionId);
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    _state.unwatchChat(widget.pcId, widget.sessionId);
    _input.dispose();
    _scroll.dispose();
    _cardsScroll.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    _syncCards();
    setState(() {});
  }

  /// Pending requests of this session (`request.session` = first 8 chars of
  /// the session id), oldest first so the newest card sits next to the input.
  List<PendingRequest> _pendingRequests() {
    final short = _short(widget.sessionId);
    if (short.isEmpty) return const <PendingRequest>[];
    final out = <PendingRequest>[
      for (final r in _state.requests)
        if (r.pcId == widget.pcId && r.request.session == short) r,
    ];
    out.sort((a, b) => a.request.ts.compareTo(b.request.ts));
    return out;
  }

  /// Scrolls to a new card, and tells why a card went away when it was not
  /// answered here ("Answered on the PC").
  void _syncCards() {
    final now = <String, bool>{
      for (final r in _pendingRequests()) r.key: r.answered || _sent.contains(r.key),
    };
    final added = now.keys.any((k) => !_cards.containsKey(k));
    String? note;
    for (final e in _cards.entries) {
      if (now.containsKey(e.key)) continue;
      _sent.remove(e.key);
      note = _resolvedNote(_state.resolvedBy[e.key] ?? '', e.value) ?? note;
    }
    _cards = now;
    if (added) _scrollToBottomSoon();
    // An open answer screen on top reports it itself.
    if (note != null && (ModalRoute.isCurrentOf(context) ?? true)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
    }
  }

  /// SnackBar text for a request that went away; null when answered here.
  static String? _resolvedNote(String by, bool answeredHere) {
    switch (by) {
      case 'pc':
        return 'Answered on the PC';
      case 'timeout':
        return 'The request expired';
      case 'phone':
        return answeredHere ? null : 'Answered from a phone';
      default:
        return answeredHere ? null : 'Answered on the PC';
    }
  }

  /// After the next frame: chat to its newest message, cards to the newest.
  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.minScrollExtent, // reversed list: bottom
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      if (_cardsScroll.hasClients) {
        _cardsScroll.animateTo(
          _cardsScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openRequest(PendingRequest r) {
    Navigator.of(context).push(AnswerScreen.route(r.pcId, r.request.id));
  }

  /// Same path as the answer screen ([AppState.answer]).
  Future<void> _answer(PendingRequest r, Map<String, dynamic> answer) async {
    if (r.answered || _sent.contains(r.key)) return;
    setState(() => _sent.add(r.key));
    await _state.answer(r.pcId, r.request.id, answer);
  }

  void _onInputChanged() {
    final v = _input.text.trim().isNotEmpty;
    if (v != _canSend) setState(() => _canSend = v);
  }

  Future<void> _refresh() => _state.refreshChat(widget.pcId, widget.sessionId);

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await _state.sendMessage(widget.pcId, widget.sessionId, text);
  }

  void _toggle(String id) => setState(() {
        if (!_expanded.remove(id)) _expanded.add(id);
      });

  MarkdownStyleSheet _styleSheet(ThemeData theme) {
    if (_md != null && identical(_mdTheme, theme)) return _md!;
    final cs = theme.colorScheme;
    _mdTheme = theme;
    _md = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium,
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        backgroundColor: cs.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      codeblockPadding: const EdgeInsets.all(8),
    );
    return _md!;
  }

  void _copyLink(String? href) {
    if (href == null || href.isEmpty) return;
    Clipboard.setData(ClipboardData(text: href));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  @override
  Widget build(BuildContext context) {
    final entry = _state.findSession(widget.pcId, widget.sessionId);
    final session = entry?.session;
    final chat = _state.chatOf(widget.pcId, widget.sessionId);
    final outgoing = _state.outgoingOf(widget.pcId, widget.sessionId);
    final pending = _pendingRequests();
    final waiting = pending.any((r) => !r.answered && !_sent.contains(r.key));
    final cs = Theme.of(context).colorScheme;

    final title = session?.displayTitle ??
        ((chat?.title.isNotEmpty ?? false) ? chat!.title : 'Session ${_short(widget.sessionId)}');
    final sub = <String>[
      if (session != null && session.project.isNotEmpty) session.project,
      entry?.pcName ?? _state.pcNameFor(widget.pcId),
    ].join(' · ');

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
          ],
        ),
        actions: [
          if (session != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: SessionStateChip(session: session)),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, box) => Column(
          children: [
            if (chat?.loading ?? false) const LinearProgressIndicator(minHeight: 2),
            if (chat != null && chat.error.isNotEmpty)
              _ErrorBanner(text: chat.error, onRetry: _refresh),
            Expanded(child: _list(context, chat, outgoing, session)),
            if (pending.isNotEmpty) _requestCards(pending, box.maxHeight * 0.45),
            _inputBar(
              context,
              session,
              entry?.pcName ?? _state.pcNameFor(widget.pcId),
              waiting: waiting,
            ),
          ],
        ),
      ),
    );
  }

  static String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

  /// Pending requests of the session, pinned above the input bar (newest
  /// last); scrollable when they need more than [maxHeight].
  Widget _requestCards(List<PendingRequest> pending, double maxHeight) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        controller: _cardsScroll,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final r in pending)
              _RequestCard(
                key: ValueKey<String>(r.key),
                entry: r,
                sending: r.answered || _sent.contains(r.key),
                onOpen: () => _openRequest(r),
                onAnswer: (Map<String, dynamic> a) => _answer(r, a),
              ),
          ],
        ),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    ChatState? chat,
    List<OutgoingMessage> outgoing,
    CcSession? session,
  ) {
    final cs = Theme.of(context).colorScheme;
    if (chat == null || (!chat.loaded && chat.loading)) {
      return const Center(child: CircularProgressIndicator());
    }
    final rows = _rows(context, chat.items, outgoing, session);
    if (rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                chat.loaded ? 'No messages yet.' : 'Pull down to load the chat.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.outline),
              ),
            ),
          ],
        ),
      );
    }
    // Reversed: starts at the newest message and stays there as items arrive.
    // RefreshIndicator handles reversed lists (pull down at the oldest end).
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        itemCount: rows.length,
        itemBuilder: (context, i) => rows[rows.length - 1 - i],
      ),
    );
  }

  /// Chat rows in chronological order: consecutive tool items are grouped;
  /// messages sent from this phone get their send status (on the matching
  /// `phone` item, or as a local bubble until the chat shows it).
  List<Widget> _rows(
    BuildContext context,
    List<ChatItem> items,
    List<OutgoingMessage> outgoing,
    CcSession? session,
  ) {
    final matched = <int, OutgoingMessage>{};
    final pending = <OutgoingMessage>[];
    for (final m in outgoing) {
      var found = -1;
      if (m.status != SendStatus.rejected) {
        for (var i = 0; i < items.length; i++) {
          final it = items[i];
          if (matched.containsKey(i) || it.role != ChatRole.phone) continue;
          // The daemon names phone items `phone-<client_id>`; text + time as fallback.
          if (it.id == 'phone-${m.clientId}' ||
              it.id == m.clientId ||
              (it.text.trim() == m.text && (it.ts == 0 || it.ts >= m.ts - 10 * 60 * 1000))) {
            found = i;
            break;
          }
        }
      }
      if (found >= 0) {
        matched[found] = m;
      } else {
        pending.add(m);
      }
    }

    final md = _styleSheet(Theme.of(context));
    final rows = <Widget>[];
    var i = 0;
    while (i < items.length) {
      final it = items[i];
      if (it.role == ChatRole.tool) {
        var j = i;
        while (j < items.length && items[j].role == ChatRole.tool) {
          j++;
        }
        final group = items.sublist(i, j);
        final id = 'g:${group.first.id.isEmpty ? '$i' : group.first.id}';
        if (group.length == 1) {
          rows.add(_ToolLine(
            item: group.first,
            expanded: _expanded.contains(id),
            onTap: () => _toggle(id),
          ));
        } else {
          rows.add(_ToolGroup(
            items: group,
            expanded: _expanded.contains(id),
            onToggle: () => _toggle(id),
          ));
        }
        i = j;
        continue;
      }
      final m = matched[i];
      rows.add(_Bubble(
        role: it.role,
        text: it.text,
        ts: it.ts,
        status: m == null ? null : _statusLabel(m, session),
        rejected: false,
        styleSheet: md,
        onTapLink: _copyLink,
      ));
      i++;
    }
    for (final m in pending) {
      rows.add(_Bubble(
        role: ChatRole.phone,
        text: m.text,
        ts: m.ts,
        status: _statusLabel(m, session),
        rejected: m.status == SendStatus.rejected,
        styleSheet: md,
        onTapLink: _copyLink,
      ));
    }
    return rows;
  }

  static String _statusLabel(OutgoingMessage m, CcSession? s) {
    switch (m.status) {
      case SendStatus.sending:
        return 'Sending…';
      case SendStatus.delivered:
        return 'Delivered';
      case SendStatus.queued:
        // Delivered by the next `listen`, i.e. once Claude finishes.
        return s != null && s.queued == 0 ? 'Delivered' : 'Queued — Claude gets it when it finishes';
      default:
        return 'Rejected: ${m.reason.isEmpty ? 'the PC refused the message' : m.reason}';
    }
  }

  /// [waiting]: a request card of this session is not answered yet.
  Widget _inputBar(BuildContext context, CcSession? s, String pcName, {bool waiting = false}) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    String? blocked;
    if (s != null && s.ended) {
      blocked = 'This session is closed.';
    } else if (s != null && s.readOnly) {
      blocked = 'Claude is running agents at high effort — read-only until it finishes.';
    }
    String? hint;
    if (blocked == null) {
      if (waiting) {
        hint = 'Claude is waiting for your answer above';
      } else if (_state.statusOf(widget.pcId) != PcStatus.connected) {
        hint = '$pcName is not connected — a message waits up to a minute for it.';
      } else if (s != null && s.state == SessionState.idle && !s.listening) {
        hint = 'This session is not listening — run `ccnotify install` on the PC and '
            'send one message from the PC first.';
      } else if (s != null && (s.state == SessionState.working || s.state == SessionState.waiting)) {
        hint = 'Claude is busy — your message is queued until it finishes.';
      }
    }
    return Material(
      color: cs.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: blocked != null
              ? Row(
                  children: [
                    Icon(Icons.lock_outline, size: 20, color: cs.outline),
                    const SizedBox(width: 12),
                    Expanded(child: Text(blocked, style: t.bodyMedium?.copyWith(color: cs.outline))),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (hint != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                        child: Text(hint, style: t.bodySmall?.copyWith(color: cs.outline)),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _input,
                            minLines: 1,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: 'Message Claude…',
                              isDense: true,
                              filled: true,
                              fillColor: cs.surface,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: 'Send',
                          onPressed: _canSend ? _send : null,
                          icon: const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

String _clock(int ts) {
  if (ts <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
  return '${t.year}-${two(t.month)}-${two(t.day)} $hm';
}

/// A user / phone (right) or assistant (left, Markdown) message.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.role,
    required this.text,
    required this.ts,
    required this.status,
    required this.rejected,
    required this.styleSheet,
    required this.onTapLink,
  });

  final String role;
  final String text;
  final int ts;
  final String? status;
  final bool rejected;
  final MarkdownStyleSheet styleSheet;
  final void Function(String? href) onTapLink;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final mine = role != ChatRole.assistant;
    final phone = role == ChatRole.phone;
    final bg = !mine
        ? cs.surfaceContainerHigh
        : phone
            ? cs.tertiaryContainer
            : cs.primaryContainer;
    final fg = !mine
        ? cs.onSurface
        : phone
            ? cs.onTertiaryContainer
            : cs.onPrimaryContainer;
    final footer = <String>[
      if (phone) '📱 from phone',
      if (_clock(ts).isNotEmpty) _clock(ts),
    ].join(' · ');

    final Widget body = mine
        ? SelectableText(text, style: t.bodyMedium?.copyWith(color: fg))
        : MarkdownBody(
            data: text,
            selectable: true,
            styleSheet: styleSheet,
            onTapLink: (String linkText, String? href, String title) => onTapLink(href),
            imageBuilder: (Uri uri, String? title, String? alt) => Text(
              '[image${(alt ?? '').isEmpty ? '' : ': $alt'}]',
              style: t.bodySmall?.copyWith(color: cs.outline),
            ),
          );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width * (mine ? 0.82 : 0.92)),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 16 : 4),
              bottomRight: Radius.circular(mine ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              body,
              if (footer.isNotEmpty || status != null) ...[
                const SizedBox(height: 4),
                Text(
                  [footer, status ?? ''].where((s) => s.isNotEmpty).join(' · '),
                  style: t.labelSmall?.copyWith(
                    color: rejected ? cs.error : fg.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One tool call as a compact grey line; tap to show it in full.
class _ToolLine extends StatelessWidget {
  const _ToolLine({required this.item, required this.expanded, required this.onTap});

  final ChatItem item;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(color: cs.outline, fontSize: 12.5);
    final tool = item.tool.isEmpty ? 'Tool' : item.tool;
    final detail = item.text == item.tool ? '' : item.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.build_outlined, size: 14, color: cs.outline),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: tool, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (detail.isNotEmpty)
                      TextSpan(text: '  $detail', style: const TextStyle(fontFamily: 'monospace')),
                  ],
                ),
                style: style,
                maxLines: expanded ? null : 1,
                overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Consecutive tool calls, collapsed to one line ("5 tool calls · Bash, Edit…").
class _ToolGroup extends StatelessWidget {
  const _ToolGroup({required this.items, required this.expanded, required this.onToggle});

  final List<ChatItem> items;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final names = <String>[];
    for (final it in items) {
      final n = it.tool.isEmpty ? 'Tool' : it.tool;
      if (!names.contains(n)) names.add(n);
    }
    final style = TextStyle(color: cs.outline, fontSize: 12.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
            child: Row(
              children: [
                Icon(Icons.build_outlined, size: 14, color: cs.outline),
                const SizedBox(width: 6),
                Text('${items.length} tool calls',
                    style: style.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    names.join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: cs.outline),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final it in items) _ToolLine(item: it, expanded: true, onTap: null),
              ],
            ),
          ),
      ],
    );
  }
}

/// A pending request of the session (permission / question / plan) with quick
/// answers; tapping the card body opens the full answer screen.
class _RequestCard extends StatelessWidget {
  const _RequestCard({
    super.key,
    required this.entry,
    required this.sending,
    required this.onOpen,
    required this.onAnswer,
  });

  final PendingRequest entry;
  final bool sending; // answered, waiting for `resolved`
  final VoidCallback onOpen;
  final void Function(Map<String, dynamic> answer) onAnswer;

  /// Exactly one single-select question: one button per option.
  static RequestQuestion? _singleQuestion(CcRequest r) {
    if (r.kind != RequestKind.question || r.questions.length != 1) return null;
    final q = r.questions.first;
    if (q.multiSelect || q.options.isEmpty) return null;
    return q;
  }

  @override
  Widget build(BuildContext context) {
    final r = entry.request;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final title = r.title.isEmpty ? AnswerScreen.kindLabel(r.kind) : r.title;
    final summary = r.summary.isNotEmpty ? r.summary : r.detail;
    final summaryStyle = t.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
      fontFamily: r.kind == RequestKind.permission ? 'monospace' : null,
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: cs.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.primary, width: 1.5),
      ),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(AnswerScreen.iconFor(r.kind), size: 20, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (summary.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: summaryStyle,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 20, color: cs.outline),
                ],
              ),
              const SizedBox(height: 8),
              if (sending) _sendingRow(context) else _actions(context, r),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sendingRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
          ),
          const SizedBox(width: 10),
          Text(
            'Sending…',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, CcRequest r) {
    final cs = Theme.of(context).colorScheme;
    final filled = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final outlined = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final danger = OutlinedButton.styleFrom(
      foregroundColor: cs.error,
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final plain = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final List<Widget> buttons;
    switch (r.kind) {
      case RequestKind.plan:
        buttons = <Widget>[
          FilledButton(
            style: filled,
            onPressed: () => onAnswer(Answers.approve()),
            child: const Text('Approve'),
          ),
          OutlinedButton(
            style: danger,
            onPressed: () => onAnswer(Answers.reject()),
            child: const Text('Reject'),
          ),
          TextButton(style: plain, onPressed: onOpen, child: const Text('Read plan')),
        ];
        break;
      case RequestKind.question:
        final q = _singleQuestion(r);
        if (q == null) {
          buttons = <Widget>[
            FilledButton(style: filled, onPressed: onOpen, child: const Text('Answer')),
          ];
        } else {
          buttons = <Widget>[
            for (final o in q.options)
              FilledButton.tonal(
                style: filled,
                onPressed: () => onAnswer(Answers.questions(<String, String>{q.question: o.label})),
                child: Text(o.label),
              ),
            OutlinedButton(style: outlined, onPressed: onOpen, child: const Text('Other…')),
          ];
        }
        break;
      default: // permission
        buttons = <Widget>[
          FilledButton(
            style: filled,
            onPressed: () => onAnswer(Answers.allow()),
            child: const Text('Allow'),
          ),
          if (r.canAllowAlways)
            FilledButton.tonal(
              style: filled,
              onPressed: () => onAnswer(Answers.allowAlways()),
              child: const Text('Always'),
            ),
          OutlinedButton(
            style: danger,
            onPressed: () => onAnswer(Answers.deny()),
            child: const Text('Deny'),
          ),
        ];
    }
    return Wrap(spacing: 8, runSpacing: 6, children: buttons);
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 20, color: cs.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: TextStyle(color: cs.onErrorContainer))),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
