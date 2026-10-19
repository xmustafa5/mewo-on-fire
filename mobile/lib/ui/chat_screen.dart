import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../models.dart';
import '../requests.dart' show Answers;
import '../voice_input.dart';
import 'answer_screen.dart';
import 'artifact_screen.dart';
import 'history_tab.dart' show SheetAction;
import 'keyboard_hide_button.dart';
import 'theme/ember.dart';
import 'theme/flame.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// One session's chat (PROTOCOL.md v1.2): Claude's replies as a running
/// document, what was typed on the PC and on this phone as bubbles, tool
/// calls as a quiet rail, and an input bar to continue the session from the
/// phone. Opened from the Sessions tab, a History item or by tapping an event
/// notification. Pending v1.1 requests of the session (permission / question
/// / plan) are pinned as cards above the input bar, with quick answers.
///
/// Messages are Markdown and can carry images (v1.3). A long press on one
/// opens its options (reply, copy, select text); the input bar can attach up
/// to four pictures. The open pull requests of the session's repository
/// (v1.6) sit above the input, like Claude Desktop's.
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
  final Map<Color, MarkdownStyleSheet> _mdMine = <Color, MarkdownStyleSheet>{};

  /// Same limits as the PC (PROTOCOL.md v1.3).
  static const int _maxImages = 4;
  static const int _maxImageBytes = 2500000;

  final ImagePicker _picker = ImagePicker();

  /// Pictures to send with the next message.
  final List<Uint8List> _attachments = <Uint8List>[];

  /// The message being replied to (quoted above the next message).
  _ReplyTarget? _replyTo;

  /// Voice message: being recorded, or being turned into text.
  _Voice _voice = _Voice.idle;
  DateTime _voiceStart = DateTime.now();
  Timer? _voiceTimer;

  /// What the last voice message put into the box, to replace it when it is
  /// heard again in the other language.
  String _voiceText = '';

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
    _voiceTimer?.cancel();
    if (_voice == _Voice.recording) unawaited(VoiceInput.cancel());
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
    if (added) {
      HapticFeedback.mediumImpact();
      _scrollToBottomSoon();
    }
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
          duration: Motion.base,
          curve: Motion.easeOut,
        );
      }
      if (_cardsScroll.hasClients) {
        _cardsScroll.animateTo(
          _cardsScroll.position.maxScrollExtent,
          duration: Motion.base,
          curve: Motion.easeOut,
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
    HapticFeedback.mediumImpact();
    setState(() => _sent.add(r.key));
    await _state.answer(r.pcId, r.request.id, answer);
  }

  void _onInputChanged() {
    final v = _input.text.trim().isNotEmpty || _attachments.isNotEmpty;
    if (v != _canSend) setState(() => _canSend = v);
  }

  Future<void> _refresh() => _state.refreshChat(widget.pcId, widget.sessionId);

  Future<void> _send() async {
    final typed = _input.text.trim();
    if (typed.isEmpty && _attachments.isEmpty) return;
    HapticFeedback.lightImpact();
    final reply = _replyTo;
    final text = reply == null ? typed : '${_quote(reply.text)}\n\n$typed'.trim();
    final images = List<Uint8List>.of(_attachments);
    _input.clear();
    setState(() {
      _attachments.clear();
      _replyTo = null;
      _canSend = false;
    });
    _scrollToBottomSoon();
    await _state.sendMessage(widget.pcId, widget.sessionId, text, images: images);
  }

  /// The start of [text] as a one-paragraph Markdown quote, so Claude sees
  /// what the reply is about: its prose up to the first code block or table,
  /// without the quotes it carried itself.
  static String _quote(String text) {
    final prose = <String>[];
    for (final line in text.split('\n')) {
      final l = line.trim();
      if (l.startsWith('```') || l.startsWith('|')) break;
      if (l.isNotEmpty && !l.startsWith('>')) prose.add(l);
    }
    var s = prose.join(' ').replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) s = '…';
    if (s.length > 240) s = '${s.substring(0, 240).trimRight()}…';
    return '> $s';
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---- voice messages ----

  String get _voiceLanguage => VoiceInput.languageFor(_state.settings.voiceLanguage);

  Future<void> _voiceRecord() async {
    if (_voice != _Voice.idle) return;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await VoiceInput.start();
    } catch (e) {
      _toast(VoiceInput.errorText(e));
      return;
    }
    if (!mounted) {
      unawaited(VoiceInput.cancel());
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _voice = _Voice.recording;
      _voiceStart = DateTime.now();
    });
    _voiceTimer?.cancel();
    _voiceTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _voice != _Voice.recording) return;
      if (DateTime.now().difference(_voiceStart) >= VoiceInput.maxLength) {
        unawaited(_voiceDone()); // the recorder stopped by itself
      } else {
        setState(() {});
      }
    });
  }

  void _voiceCancel() {
    _voiceTimer?.cancel();
    unawaited(VoiceInput.cancel());
    setState(() => _voice = _Voice.idle);
  }

  void _voiceSwitchLanguage() {
    HapticFeedback.selectionClick();
    unawaited(_state.updateSettings(
        _state.settings.copyWith(voiceLanguage: VoiceInput.other(_voiceLanguage))));
  }

  /// Stops the recording and puts what was said into the box, for a look
  /// before it is sent.
  Future<void> _voiceDone() async {
    if (_voice != _Voice.recording) return;
    _voiceTimer?.cancel();
    final language = _voiceLanguage;
    setState(() => _voice = _Voice.working);
    try {
      _voiceInsert(await VoiceInput.stop(language), language, replaceLast: false);
    } catch (e) {
      _toast(VoiceInput.errorText(e));
    }
    if (mounted) setState(() => _voice = _Voice.idle);
  }

  /// The last recording again, as [language].
  Future<void> _voiceAgain(String language) async {
    if (_voice != _Voice.idle) return;
    setState(() => _voice = _Voice.working);
    try {
      final text = await VoiceInput.again(language);
      unawaited(_state.updateSettings(_state.settings.copyWith(voiceLanguage: language)));
      _voiceInsert(text, language, replaceLast: true);
    } catch (e) {
      _toast(VoiceInput.errorText(e));
    }
    if (mounted) setState(() => _voice = _Voice.idle);
  }

  void _voiceInsert(String text, String language, {required bool replaceLast}) {
    if (!mounted || text.isEmpty) return;
    var before = _input.text;
    if (replaceLast && _voiceText.isNotEmpty && before.endsWith(_voiceText)) {
      before = before.substring(0, before.length - _voiceText.length);
    }
    final joined = before.isEmpty || before.endsWith(' ') || before.endsWith('\n')
        ? '$before$text'
        : '$before $text';
    _voiceText = text;
    _input.value = TextEditingValue(
      text: joined,
      selection: TextSelection.collapsed(offset: joined.length),
    );
    final other = VoiceInput.other(language);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Heard as ${VoiceInput.languages[language]}. Check it, then send.'),
        action: SnackBarAction(
          label: 'It was ${VoiceInput.languages[other]}',
          onPressed: () => _voiceAgain(other),
        ),
      ));
  }

  // ---- pictures ----

  Future<void> _attach() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add pictures', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 14),
              SheetAction(
                icon: Icons.photo_library_outlined,
                color: Ember.mewo,
                title: 'Photo library',
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              const SizedBox(height: 8),
              SheetAction(
                icon: Icons.photo_camera_outlined,
                color: Ember.amber,
                title: 'Take a photo',
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );
    if (source != null) await _pick(source);
  }

  /// Pictures are scaled down to 1600 px and re-encoded, which keeps them
  /// well under the size the PC accepts.
  Future<void> _pick(ImageSource source) async {
    final room = _maxImages - _attachments.length;
    if (room <= 0) return;
    try {
      final List<XFile> files;
      if (source == ImageSource.camera) {
        final shot = await _picker.pickImage(
            source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
        files = <XFile>[?shot];
      } else {
        files = await _picker.pickMultiImage(
            maxWidth: 1600, maxHeight: 1600, imageQuality: 80, limit: room);
      }
      final picked = <Uint8List>[];
      var tooLarge = false;
      for (final f in files.take(room)) {
        final bytes = await f.readAsBytes();
        if (bytes.length > _maxImageBytes) {
          tooLarge = true;
        } else {
          picked.add(bytes);
        }
      }
      if (!mounted) return;
      setState(() {
        _attachments.addAll(picked);
        _canSend = _input.text.trim().isNotEmpty || _attachments.isNotEmpty;
      });
      if (files.length > room) _toast('A message can carry $_maxImages pictures at most');
      if (tooLarge) _toast('A picture was too large to send');
    } catch (e) {
      _toast('Could not get the picture: $e');
    }
  }

  void _removeAttachment(int index) => setState(() {
        _attachments.removeAt(index);
        _canSend = _input.text.trim().isNotEmpty || _attachments.isNotEmpty;
      });

  void _viewImage(Uint8List bytes) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ImageViewer(bytes: bytes)));
  }

  // ---- message options ----

  /// Reply / copy / select text for a message; a rejected one of ours can be
  /// sent again or removed.
  Future<void> _showOptions({
    required String role,
    required String text,
    OutgoingMessage? failed,
    bool canReply = true,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                role == ChatRole.assistant ? "Claude's message" : 'Your message',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 14),
              if (canReply && failed == null && text.isNotEmpty) ...[
                SheetAction(
                  icon: Icons.reply_rounded,
                  color: Ember.amber,
                  title: 'Reply',
                  subtitle: 'Quote it above your next message',
                  onTap: () {
                    Navigator.pop(ctx);
                    _startReply(role, text);
                  },
                ),
                const SizedBox(height: 8),
              ],
              if (text.isNotEmpty) ...[
                SheetAction(
                  icon: Icons.copy_rounded,
                  color: Ember.mewo,
                  title: 'Copy',
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: text));
                    _toast('Copied');
                  },
                ),
                const SizedBox(height: 8),
                SheetAction(
                  icon: Icons.text_fields_rounded,
                  color: Ember.text2,
                  title: 'Select text',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => _SelectTextScreen(text: text)));
                  },
                ),
              ],
              if (failed != null) ...[
                const SizedBox(height: 8),
                SheetAction(
                  icon: Icons.refresh_rounded,
                  color: Ember.ok,
                  title: 'Send again',
                  onTap: () {
                    Navigator.pop(ctx);
                    _state.removeOutgoing(widget.pcId, widget.sessionId, failed.clientId);
                    _state.sendMessage(widget.pcId, widget.sessionId, failed.text,
                        images: failed.images);
                  },
                ),
                const SizedBox(height: 8),
                SheetAction(
                  icon: Icons.delete_outline_rounded,
                  color: Ember.danger,
                  title: 'Remove',
                  onTap: () {
                    Navigator.pop(ctx);
                    _state.removeOutgoing(widget.pcId, widget.sessionId, failed.clientId);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
  }

  MarkdownStyleSheet _styleSheet(ThemeData theme) {
    if (_md != null && identical(_mdTheme, theme)) return _md!;
    _mdTheme = theme;
    _mdMine.clear();
    final t = theme.textTheme;
    final mono = Ember.mono(_mdTheme == null ? context : context);
    _md = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: t.bodyMedium,
      h1: t.headlineSmall,
      h2: t.titleLarge,
      h3: t.titleMedium,
      h4: t.titleSmall,
      h5: t.titleSmall,
      h6: t.titleSmall,
      strong: const TextStyle(fontWeight: FontWeight.w700, color: Ember.text),
      em: const TextStyle(fontStyle: FontStyle.italic),
      listBullet: t.bodyMedium?.copyWith(color: Ember.amber),
      a: t.bodyMedium?.copyWith(color: Ember.mewoSoft, decoration: TextDecoration.underline),
      code: TextStyle(
        fontFamily: mono,
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
      blockquote: t.bodyMedium?.copyWith(color: Ember.text2),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Ember.ember, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      horizontalRuleDecoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Ember.line)),
      ),
      tableBorder: TableBorder.all(color: Ember.line, borderRadius: BorderRadius.circular(8)),
      tableHead: t.labelLarge,
      tableBody: t.bodySmall?.copyWith(color: Ember.text),
      tableCellsPadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
    );
    return _md!;
  }

  /// Style of our own bubbles: the bubble's text colour, a bar for quotes.
  MarkdownStyleSheet _mineSheet(ThemeData theme, Color fg) {
    return _mdMine.putIfAbsent(fg, () {
      final base = theme.textTheme.bodyMedium?.copyWith(color: fg);
      return _styleSheet(theme).copyWith(
        p: base,
        listBullet: base,
        strong: TextStyle(fontWeight: FontWeight.w700, color: fg),
        a: base?.copyWith(decoration: TextDecoration.underline),
        code: TextStyle(
          fontFamily: Ember.mono(context),
          fontSize: 13,
          color: fg,
          backgroundColor: const Color(0x47000000),
        ),
        codeblockDecoration: BoxDecoration(
          color: const Color(0x47000000),
          borderRadius: BorderRadius.circular(10),
        ),
        blockquote: base?.copyWith(color: fg.withValues(alpha: 0.75)),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: fg.withValues(alpha: 0.45), width: 3)),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
      );
    });
  }

  /// Quotes [text] above the next message (long-press → Reply, or a swipe
  /// on the bubble).
  void _startReply(String role, String text) {
    HapticFeedback.selectionClick();
    setState(() => _replyTo = _ReplyTarget(role: role, text: text));
  }

  /// A link in a message opens; a link that cannot be opened is copied.
  void _copyLink(String? href) {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
      Clipboard.setData(ClipboardData(text: href));
      _toast('Link copied');
      return;
    }
    unawaited(_openUrl(href));
  }

  @override
  Widget build(BuildContext context) {
    final entry = _state.findSession(widget.pcId, widget.sessionId);
    final session = entry?.session;
    final chat = _state.chatOf(widget.pcId, widget.sessionId);
    final outgoing = _state.outgoingOf(widget.pcId, widget.sessionId);
    final pending = _pendingRequests();
    final waiting = pending.any((r) => !r.answered && !_sent.contains(r.key));
    final prs = _state.prsOf(widget.pcId, widget.sessionId);

    final title = session?.displayTitle ??
        ((chat?.title.isNotEmpty ?? false) ? chat!.title : 'Session ${_short(widget.sessionId)}');
    final sub = <String>[
      if (session != null && session.project.isNotEmpty) session.project,
      if (session != null && session.planSession > 0) 'S${session.planSession}',
      if (session != null && session.tier > 0) 'Tier ${session.tier}',
      entry?.pcName ?? _state.pcNameFor(widget.pcId),
    ].join(' · ');

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: GlassTopBar(
        title: Text(title),
        subtitle: Text(sub),
        actions: [
          if (session != null)
            AnimatedSwitcher(
              duration: Motion.base,
              transitionBuilder: fadeScaleTransition,
              child: HeatChip(key: ValueKey<String>(session.state), state: session.state, compact: true),
            ),
          GhostIconButton(icon: Icons.refresh_rounded, tooltip: 'Refresh', onPressed: _refresh),
        ],
      ),
      body: EmberBackground(
        animate: false,
        child: LayoutBuilder(
          builder: (context, box) => Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _list(context, chat, outgoing, session)),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: MediaQuery.paddingOf(context).top,
                      child: AnimatedSwitcher(
                        duration: Motion.base,
                        transitionBuilder: fadeUpTransition,
                        child: chat != null && chat.error.isNotEmpty
                            ? _ErrorBanner(text: chat.error, onRetry: _refresh)
                            : (chat?.loading ?? false)
                                ? const _LoadingLine()
                                : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
              _StatusStrip(session: session, hasCards: pending.isNotEmpty),
              if (session != null && session.artifacts.isNotEmpty)
                _ArtifactStrip(artifacts: session.artifacts, onOpen: _openArtifact, onCopy: _copyArtifactLink),
              if (prs != null) _PrStrip(list: prs, onOpen: _showPr),
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
      ),
    );
  }

  static String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

  /// In place when the PC kept the files, else on claude.ai.
  Future<void> _openArtifact(SessionArtifact a) async {
    if (!a.local) return _openUrl(a.url);
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ArtifactScreen(pcId: widget.pcId, sessionId: widget.sessionId, artifact: a)),
    );
  }

  void _copyArtifactLink(String url) {
    Clipboard.setData(ClipboardData(text: url));
    _toast('Link copied');
  }

  // ---- pull requests (v1.6) ----

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) _toast('Could not open the link');
    } catch (_) {
      _toast('Could not open the link');
    }
  }

  /// The checks of a pull request, and what to do about it.
  Future<void> _showPr(PullRequest pr) async {
    final list = _state.prsOf(widget.pcId, widget.sessionId);
    final t = Theme.of(context).textTheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.call_merge_rounded, size: 22, color: _PrStrip.colorOf(pr.ci)),
                  const SizedBox(width: 8),
                  Text(
                    '#${pr.number}',
                    style: t.titleMedium?.copyWith(fontFamily: Ember.mono(context), color: Ember.text2),
                  ),
                  if (pr.draft) ...[
                    const SizedBox(width: 10),
                    Text('Draft', style: t.labelMedium?.copyWith(color: Ember.text3)),
                  ],
                  const Spacer(),
                  if (pr.review.isNotEmpty) _ReviewPill(review: pr.review),
                ],
              ),
              const SizedBox(height: 10),
              Text(pr.title, style: t.titleMedium),
              const SizedBox(height: 6),
              Text(
                '${list?.repo ?? ''} · ${pr.branch}',
                style: t.bodySmall?.copyWith(color: Ember.text3, fontFamily: Ember.mono(context), fontSize: 12),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _Diff(additions: pr.additions, deletions: pr.deletions, size: 13),
                  if (pr.author.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Text('by ${pr.author}', style: t.bodySmall?.copyWith(color: Ember.text3)),
                  ],
                  if (pr.current) ...[
                    const SizedBox(width: 12),
                    Text('checked out here', style: t.bodySmall?.copyWith(color: Ember.amber)),
                  ],
                ],
              ),
              if (pr.checks.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  'CHECKS',
                  style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.4),
                ),
                const SizedBox(height: 8),
                GlassCard(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                  radius: 16,
                  fill: Ember.surface2.withValues(alpha: 0.8),
                  child: Column(
                    children: [
                      for (final c in pr.checks.take(8))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              GlowDot(color: _PrStrip.colorOf(c.state), size: 8, live: c.state == 'pending'),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: Ember.text)),
                              ),
                              Text(
                                c.state == 'pass' ? 'passed' : c.state == 'fail' ? 'failed' : 'running',
                                style: t.labelSmall?.copyWith(color: _PrStrip.colorOf(c.state)),
                              ),
                            ],
                          ),
                        ),
                      if (pr.checks.length > 8)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text('+${pr.checks.length - 8} more', style: t.labelSmall?.copyWith(color: Ember.text3)),
                        ),
                    ],
                  ),
                ),
              ],
              _SelfCheck(pcId: widget.pcId, sessionId: widget.sessionId),
              const SizedBox(height: 18),
              if (pr.ci == 'fail') ...[
                EmberButton(
                  label: 'Ask Claude to fix the checks',
                  icon: Icons.auto_fix_high_rounded,
                  expand: true,
                  onPressed: () {
                    Navigator.pop(ctx);
                    _useSuggestion(
                        'The checks on PR #${pr.number} (${pr.title}) are failing. Look at the failures and fix the cause.');
                  },
                ),
                const SizedBox(height: 10),
              ],
              EmberButton(
                label: 'Open on GitHub',
                icon: Icons.open_in_new_rounded,
                style: pr.ci == 'fail' ? EmberButtonStyle.secondary : EmberButtonStyle.blue,
                expand: true,
                onPressed: pr.url.isEmpty
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _openUrl(pr.url);
                      },
              ),
              const SizedBox(height: 10),
              EmberButton(
                label: 'Copy link',
                icon: Icons.link_rounded,
                style: EmberButtonStyle.ghost,
                expand: true,
                onPressed: pr.url.isEmpty
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        Clipboard.setData(ClipboardData(text: pr.url));
                        _toast('Link copied');
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

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
              FadeSlideIn(
                key: ValueKey<String>('card:${r.key}'),
                child: _RequestCard(
                  entry: r,
                  sending: r.answered || _sent.contains(r.key),
                  onOpen: () => _openRequest(r),
                  onAnswer: (Map<String, dynamic> a) => _answer(r, a),
                ),
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
    final topInset = MediaQuery.paddingOf(context).top + 12;
    if (chat == null || (!chat.loaded && chat.loading)) {
      return Center(
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: const FlameMark(size: 48),
        ),
      );
    }
    final rows = _rows(context, chat.items, outgoing, session);
    if (rows.isEmpty) {
      return RefreshIndicator(
        color: Ember.amber,
        backgroundColor: Ember.surface2,
        edgeOffset: topInset,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: EdgeInsets.only(top: topInset + (chat.error.isNotEmpty ? 64 : 0)),
          children: [
            EmptyState(
              icon: Icons.forum_outlined,
              title: chat.loaded ? 'No messages yet' : 'Pull to load the chat',
              body: chat.loaded
                  ? 'Say something below and Claude picks it up in this session.'
                  : 'The chat is fetched from the PC when you pull down.',
            ),
          ],
        ),
      );
    }
    // Reversed: starts at the newest message and stays there as items arrive.
    // RefreshIndicator handles reversed lists (pull down at the oldest end).
    return RefreshIndicator(
      color: Ember.amber,
      backgroundColor: Ember.surface2,
      edgeOffset: topInset,
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(14, topInset, 14, 10),
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final row = rows[rows.length - 1 - i];
          return FadeSlideIn(
            key: row.key,
            delay: Motion.stagger(i, step: 30, max: 8),
            offset: const Offset(0, 14),
            child: row,
          );
        },
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

    final theme = Theme.of(context);
    final md = _styleSheet(theme);
    MarkdownStyleSheet sheetFor(String role) {
      if (role == ChatRole.assistant) return md;
      return _mineSheet(theme, role == ChatRole.phone ? Colors.white : Ember.text);
    }

    final canReply = !(session?.ended ?? false) && !(session?.readOnly ?? false);
    final rows = <Widget>[];
    var i = 0;
    while (i < items.length) {
      final it = items[i];
      final rowId = it.id.isEmpty ? '${it.ts}:$i' : it.id;
      if (it.role == ChatRole.tool) {
        var j = i;
        while (j < items.length && items[j].role == ChatRole.tool) {
          j++;
        }
        final group = items.sublist(i, j);
        final id = 'g:${group.first.id.isEmpty ? '$i' : group.first.id}';
        if (group.length == 1) {
          rows.add(_ToolLine(
            key: ValueKey<String>(id),
            item: group.first,
            expanded: _expanded.contains(id),
            onTap: () => _toggle(id),
          ));
        } else {
          rows.add(_ToolGroup(
            key: ValueKey<String>(id),
            items: group,
            expanded: _expanded.contains(id),
            onToggle: () => _toggle(id),
          ));
        }
        i = j;
        continue;
      }
      final m = matched[i];
      // Pictures we sent ourselves are already here; others come from the PC.
      final local = m != null && m.images.length == it.images.length;
      final text = it.images.isEmpty ? it.text : _withoutImageMarks(it.text);
      final replyable = canReply && text.isNotEmpty;
      rows.add(_SwipeToReply(
        key: ValueKey<String>('m:$rowId'),
        enabled: replyable,
        onReply: () => _startReply(it.role, text),
        child: _Bubble(
          role: it.role,
          text: text,
          ts: it.ts,
          status: m == null ? null : _statusLabel(m, session),
          rejected: false,
          styleSheet: sheetFor(it.role),
          onTapLink: _copyLink,
          images: <Widget>[
            for (var n = 0; n < it.images.length; n++)
              local
                  ? _ChatImageTile.bytes(m.images[n], onOpen: _viewImage)
                  : _ChatImageTile.remote(widget.pcId, widget.sessionId, it.images[n],
                      onOpen: _viewImage),
          ],
          onLongPress: () => _showOptions(role: it.role, text: text, canReply: canReply),
        ),
      ));
      i++;
    }
    for (final m in pending) {
      final rejected = m.status == SendStatus.rejected;
      rows.add(_Bubble(
        key: ValueKey<String>('out:${m.clientId}'),
        role: ChatRole.phone,
        text: m.text,
        ts: m.ts,
        status: _statusLabel(m, session),
        rejected: rejected,
        styleSheet: sheetFor(ChatRole.phone),
        onTapLink: _copyLink,
        images: <Widget>[
          for (final bytes in m.images) _ChatImageTile.bytes(bytes, onOpen: _viewImage),
        ],
        onLongPress: () => _showOptions(
            role: ChatRole.phone, text: m.text, failed: rejected ? m : null, canReply: false),
      ));
    }
    return rows;
  }

  /// The PC puts "[image]" in the text for every picture (for apps that do
  /// not show them); the pictures themselves are shown here.
  static String _withoutImageMarks(String text) =>
      text.split('\n').where((l) => l.trim() != '[image]').join('\n').trim();

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

  /// A suggested message goes into the box, to be changed or sent.
  void _useSuggestion(String text) {
    HapticFeedback.selectionClick();
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// [waiting]: a request card of this session is not answered yet.
  Widget _inputBar(BuildContext context, CcSession? s, String pcName, {bool waiting = false}) {
    final suggestions = _state.suggestionsOf(widget.pcId, widget.sessionId);
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
        hint = 'This session is not listening — run `mewo install` on the PC and '
            'send one message from the PC first.';
      } else if (s != null && (s.state == SessionState.working || s.state == SessionState.waiting)) {
        hint = 'Claude is busy — your message is queued until it finishes.';
      }
    }
    return GlassBar(
      border: const Border(top: BorderSide(color: Ember.line)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(blocked != null ? 16 : 8, 8, 8, 8),
          child: blocked != null
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.lock_outline_rounded, size: 18, color: Ember.text3),
                      const SizedBox(width: 12),
                      Expanded(child: Text(blocked, style: t.bodySmall?.copyWith(color: Ember.text2))),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedSize(
                      duration: Motion.base,
                      curve: Motion.easeOut,
                      alignment: Alignment.bottomCenter,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (hint != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.info_outline_rounded, size: 13, color: Ember.text3),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(hint, style: t.labelSmall?.copyWith(color: Ember.text3)),
                                  ),
                                ],
                              ),
                            ),
                          if (_replyTo != null)
                            _ReplyBar(target: _replyTo!, onCancel: () => setState(() => _replyTo = null)),
                          if (_attachments.isNotEmpty)
                            _AttachmentStrip(
                              images: _attachments,
                              onOpen: _viewImage,
                              onRemove: _removeAttachment,
                            ),
                          if (suggestions.isNotEmpty && !_canSend && _voice == _Voice.idle)
                            _Suggestions(suggestions: suggestions, onPick: _useSuggestion),
                        ],
                      ),
                    ),
                    AnimatedSwitcher(
                      duration: Motion.base,
                      transitionBuilder: fadeUpTransition,
                      child: _voice != _Voice.idle
                          ? _VoiceBar(
                              key: const ValueKey<String>('voice'),
                              working: _voice == _Voice.working,
                              elapsed: DateTime.now().difference(_voiceStart),
                              language: VoiceInput.languages[_voiceLanguage] ?? '',
                              onLanguage: _voiceSwitchLanguage,
                              onCancel: _voiceCancel,
                              onDone: _voiceDone,
                            )
                          : _inputRow(),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// Hide keyboard, attach, the message box, and send — or the microphone
  /// while the box is empty.
  Widget _inputRow() {
    final t = Theme.of(context).textTheme;
    final mic = !_canSend && VoiceInput.supported;
    return Row(
      key: const ValueKey<String>('input'),
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const KeyboardHideButton(),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: GhostIconButton(
            icon: Icons.add_photo_alternate_outlined,
            tooltip: 'Attach pictures',
            filled: false,
            onPressed: _attachments.length >= _maxImages ? null : _attach,
          ),
        ),
        Expanded(
          child: TextField(
            controller: _input,
            minLines: 1,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            style: t.bodyMedium,
            decoration: InputDecoration(
              hintText: 'Message Claude…',
              isDense: true,
              filled: true,
              fillColor: Ember.surface2.withValues(alpha: 0.9),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: const BorderSide(color: Ember.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: const BorderSide(color: Ember.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide(color: Ember.flame.withValues(alpha: 0.8), width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: AnimatedSwitcher(
            duration: Motion.base,
            transitionBuilder: fadeScaleTransition,
            child: mic
                ? _RoundAction(
                    key: const ValueKey<String>('mic'),
                    icon: Icons.mic_rounded,
                    tooltip: 'Voice message',
                    gradient: Ember.blue,
                    glow: Ember.mewo,
                    onPressed: _voiceRecord,
                  )
                : _RoundAction(
                    key: const ValueKey<String>('send'),
                    icon: Icons.arrow_upward_rounded,
                    tooltip: 'Send',
                    gradient: Ember.fire,
                    glow: Ember.flame,
                    onPressed: _canSend ? _send : null,
                  ),
          ),
        ),
      ],
    );
  }
}

enum _Voice { idle, recording, working }

/// Round gradient button at the end of the input row (send / microphone).
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.gradient,
    required this.glow,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Gradient gradient;
  final Color glow;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: PressScale(
          scale: 0.9,
          onTap: onPressed,
          child: AnimatedContainer(
            duration: Motion.base,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: enabled ? gradient : null,
              color: enabled ? null : Ember.surface3,
              border: Border.all(color: enabled ? Colors.transparent : Ember.line),
              boxShadow: enabled
                  ? [BoxShadow(color: glow.withValues(alpha: 0.45), blurRadius: 16, offset: const Offset(0, 4))]
                  : const [],
            ),
            child: Icon(icon, size: 22, color: enabled ? Colors.white : Ember.text3),
          ),
        ),
      ),
    );
  }
}

/// Thin line under the top bar while the chat is being fetched.
class _LoadingLine extends StatelessWidget {
  const _LoadingLine();

  @override
  Widget build(BuildContext context) {
    return const LinearProgressIndicator(minHeight: 2, color: Ember.amber);
  }
}

/// Between the chat and the input: what Claude is doing right now.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.session, required this.hasCards});

  final CcSession? session;
  final bool hasCards;

  @override
  Widget build(BuildContext context) {
    final s = session;
    Widget child = const SizedBox.shrink();
    if (s != null && s.state == SessionState.working) {
      child = Padding(
        key: const ValueKey<String>('working'),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
        child: Row(
          children: [
            const FlameIcon(size: 18),
            const SizedBox(width: 8),
            Breathe(
              min: 0.6,
              child: Text(
                'Claude is working…',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Ember.amber),
              ),
            ),
          ],
        ),
      );
    } else if (s != null && s.state == SessionState.waiting && !hasCards) {
      child = Padding(
        key: const ValueKey<String>('waiting'),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
        child: Row(
          children: [
            const GlowDot(color: Ember.amber, size: 8, live: true),
            const SizedBox(width: 10),
            Text(
              'Claude is waiting on the PC',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Ember.amber),
            ),
          ],
        ),
      );
    }
    return AnimatedSize(
      duration: Motion.base,
      curve: Motion.easeOut,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: Motion.base,
        transitionBuilder: fadeUpTransition,
        child: child,
      ),
    );
  }
}

/// What Claude suggests to say next, above the message box: tap one to put
/// it in the box.
class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.suggestions, required this.onPick});

  final List<String> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: Row(
        children: [
          for (var i = 0; i < suggestions.length; i++)
            FadeSlideIn(
              key: ValueKey<String>(suggestions[i]),
              delay: Motion.stagger(i, step: 70),
              offset: const Offset(16, 0),
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: PressScale(
                  onTap: () => onPick(suggestions[i]),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
                    decoration: BoxDecoration(
                      color: Ember.surface2.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Ember.amber.withValues(alpha: 0.4)),
                      boxShadow: [BoxShadow(color: Ember.amber.withValues(alpha: 0.12), blurRadius: 12)],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.auto_awesome_rounded, size: 14, color: Ember.amber),
                        const SizedBox(width: 7),
                        Text(suggestions[i], style: t.labelLarge?.copyWith(fontSize: 13.5)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Takes the place of the input row while a voice message is recorded (time,
/// language, discard, done) or turned into text.
class _VoiceBar extends StatelessWidget {
  const _VoiceBar({
    super.key,
    required this.working,
    required this.elapsed,
    required this.language,
    required this.onLanguage,
    required this.onCancel,
    required this.onDone,
  });

  final bool working;
  final Duration elapsed;
  final String language;
  final VoidCallback onLanguage;
  final VoidCallback onCancel;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (working) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Ember.amber),
            ),
            const SizedBox(width: 14),
            Text('Turning it into text…', style: t.bodyMedium?.copyWith(color: Ember.text2)),
          ],
        ),
      );
    }
    final s = elapsed.inSeconds;
    return Row(
      children: [
        GhostIconButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Discard',
          color: Ember.danger,
          onPressed: onCancel,
        ),
        const SizedBox(width: 10),
        const GlowDot(color: Ember.danger, size: 9, live: true),
        const SizedBox(width: 10),
        const _Bars(),
        const SizedBox(width: 10),
        Text(
          '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
          style: t.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        const SizedBox(width: 10),
        PressScale(
          onTap: onLanguage,
          child: Tooltip(
            message: 'Language you are speaking',
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
              decoration: BoxDecoration(
                color: Ember.surface2,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Ember.line),
              ),
              child: Row(
                children: [
                  const Icon(Icons.language_rounded, size: 15, color: Ember.text2),
                  const SizedBox(width: 5),
                  Text(language, style: t.labelMedium?.copyWith(color: Ember.text)),
                ],
              ),
            ),
          ),
        ),
        const Spacer(),
        EmberButton(label: 'Done', icon: Icons.stop_rounded, small: true, onPressed: onDone),
      ],
    );
  }
}

/// Little equalizer that moves while recording (there is no real level to
/// show; it says "listening").
class _Bars extends StatefulWidget {
  const _Bars();

  @override
  State<_Bars> createState() => _BarsState();
}

class _BarsState extends State<_Bars> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reducedMotion(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        children: [
          for (var i = 0; i < 5; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 3,
                height: 6 + 12 * (0.5 + 0.5 * math.sin(_c.value * 2 * math.pi * (1 + i * 0.15) + i * 1.3)),
                decoration: BoxDecoration(
                  gradient: Ember.fireSoft,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
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

/// A message. Claude's replies run full width like a document under a small
/// flame; what was typed on the PC sits right in a quiet bubble; what this
/// phone sent sits right in a blue one. A long press opens the options.
class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.role,
    required this.text,
    required this.ts,
    required this.status,
    required this.rejected,
    required this.styleSheet,
    required this.onTapLink,
    required this.images,
    required this.onLongPress,
  });

  final String role;
  final String text;
  final int ts;
  final String? status;
  final bool rejected;
  final MarkdownStyleSheet styleSheet;
  final void Function(String? href) onTapLink;
  final List<Widget> images;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final mine = role != ChatRole.assistant;
    final phone = role == ChatRole.phone;

    // Not selectable: a long press opens the options ("Select text" is one).
    // What we typed keeps its line breaks.
    final Widget body = MarkdownBody(
      data: text,
      softLineBreak: mine,
      styleSheet: styleSheet,
      onTapLink: (String linkText, String? href, String title) => onTapLink(href),
      imageBuilder: (Uri uri, String? title, String? alt) => Text(
        '[image${(alt ?? '').isEmpty ? '' : ': $alt'}]',
        style: t.bodySmall?.copyWith(color: Ember.text3),
      ),
    );

    if (!mine) {
      return GestureDetector(
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const FlameIcon(size: 14, animate: false),
                  const SizedBox(width: 6),
                  Text('CLAUDE', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.2)),
                  if (_clock(ts).isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(_clock(ts), style: t.labelSmall?.copyWith(color: Ember.text3, fontWeight: FontWeight.w400)),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              if (images.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: text.isEmpty ? 0 : 8),
                  child: Wrap(spacing: 6, runSpacing: 6, children: images),
                ),
              if (text.isNotEmpty) body,
            ],
          ),
        ),
      );
    }

    final fg = phone ? Colors.white : Ember.text;
    final footer = <String>[
      if (_clock(ts).isNotEmpty) _clock(ts),
      ?status,
    ].join(' · ');
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width * 0.82),
        child: GestureDetector(
          onLongPress: onLongPress,
          child: Container(
            margin: const EdgeInsets.fromLTRB(0, 6, 0, 6),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            decoration: BoxDecoration(
              gradient: phone ? Ember.blue : null,
              color: phone ? null : Ember.surface3,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(6),
              ),
              border: Border.all(
                color: rejected
                    ? Ember.danger.withValues(alpha: 0.7)
                    : phone
                        ? Colors.white.withValues(alpha: 0.12)
                        : Ember.lineStrong,
              ),
              boxShadow: phone
                  ? [BoxShadow(color: Ember.mewo.withValues(alpha: 0.3), blurRadius: 18, offset: const Offset(0, 6))]
                  : const [BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 6))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (images.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 2, bottom: text.isEmpty ? 0 : 8),
                    child: Wrap(spacing: 6, runSpacing: 6, children: images),
                  ),
                if (text.isNotEmpty) body,
                const SizedBox(height: 5),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (phone) ...[
                      Icon(Icons.smartphone_rounded, size: 11, color: fg.withValues(alpha: 0.75)),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        footer,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelSmall?.copyWith(
                          color: rejected ? Ember.danger : fg.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Drag a message sideways to reply to it: it follows the finger a little,
/// a reply arrow appears, and letting go past the threshold starts the reply.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({super.key, required this.enabled, required this.onReply, required this.child});

  final bool enabled;
  final VoidCallback onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> with SingleTickerProviderStateMixin {
  static const double _maxShift = 72;
  static const double _threshold = 48;

  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() => _shift = _release * (1 - Curves.easeOutBack.transform(_back.value))));

  double _shift = 0; // current horizontal offset of the message
  double _release = 0; // offset when the finger let go
  bool _armed = false; // past the threshold: the arrow is lit

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    if (!widget.enabled) return;
    // Right-to-left for own messages (right-aligned), left-to-right for Claude's:
    // either way towards the middle, so any horizontal drag counts.
    final next = (_shift + d.delta.dx).clamp(-_maxShift, _maxShift);
    final armed = next.abs() >= _threshold;
    if (armed && !_armed) HapticFeedback.lightImpact();
    setState(() {
      _shift = next.toDouble();
      _armed = armed;
    });
  }

  void _end(DragEndDetails d) {
    if (_armed) widget.onReply();
    _release = _shift;
    _armed = false;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final progress = (_shift.abs() / _threshold).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: () => _end(DragEndDetails()),
      child: Stack(
        alignment: _shift >= 0 ? Alignment.centerLeft : Alignment.centerRight,
        children: [
          if (progress > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Opacity(
                opacity: progress,
                child: Transform.scale(
                  scale: 0.6 + 0.4 * progress,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _armed ? Ember.amber : Ember.surface3,
                      boxShadow: _armed
                          ? [BoxShadow(color: Ember.amber.withValues(alpha: 0.5), blurRadius: 14)]
                          : const [],
                    ),
                    child: Icon(Icons.reply_rounded, size: 18, color: _armed ? Ember.bg : Ember.text2),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(_shift, 0), child: widget.child),
        ],
      ),
    );
  }
}

class _ReplyTarget {
  const _ReplyTarget({required this.role, required this.text});
  final String role;
  final String text;
}

/// "Replying to …" above the input, with the start of the quoted message.
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.target, required this.onCancel});

  final _ReplyTarget target;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final who = target.role == ChatRole.assistant ? 'Claude' : 'your message';
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: Ember.surface2.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(14),
        border: const Border(left: BorderSide(color: Ember.amber, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Replying to $who', style: t.labelMedium?.copyWith(color: Ember.amber)),
                const SizedBox(height: 2),
                Text(
                  target.text.replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall?.copyWith(color: Ember.text2),
                ),
              ],
            ),
          ),
          GhostIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Cancel reply',
            filled: false,
            size: 36,
            iconSize: 18,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// The pictures picked for the next message.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({required this.images, required this.onOpen, required this.onRemove});

  final List<Uint8List> images;
  final void Function(Uint8List bytes) onOpen;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) => Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              onTap: () => onOpen(images[i]),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Ember.lineStrong),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Image.memory(images[i], width: 64, height: 64, fit: BoxFit.cover, cacheWidth: 192),
                ),
              ),
            ),
            Positioned(
              top: -7,
              right: -7,
              child: GestureDetector(
                onTap: () => onRemove(i),
                child: Container(
                  decoration: BoxDecoration(
                    color: Ember.text,
                    shape: BoxShape.circle,
                    border: Border.all(color: Ember.bg, width: 2),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(Icons.close_rounded, size: 12, color: Ember.bg),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A picture inside a message: one we sent (bytes at hand) or one the PC has
/// (fetched on demand, see [AppState.chatImage]). Tap to see it in full.
class _ChatImageTile extends StatelessWidget {
  const _ChatImageTile.bytes(Uint8List this.bytes, {required this.onOpen})
      : pcId = '',
        sessionId = '',
        imageId = '';

  const _ChatImageTile.remote(this.pcId, this.sessionId, this.imageId, {required this.onOpen})
      : bytes = null;

  final Uint8List? bytes;
  final String pcId;
  final String sessionId;
  final String imageId;
  final void Function(Uint8List bytes) onOpen;

  static const double _size = 132;

  @override
  Widget build(BuildContext context) {
    final remote = bytes == null ? AppState.instance.chatImage(pcId, sessionId, imageId) : null;
    final data = bytes ?? remote?.bytes;
    final Widget child;
    if (data != null) {
      child = GestureDetector(
        onTap: () => onOpen(data),
        child: Image.memory(data,
            width: _size, height: _size, fit: BoxFit.cover, cacheWidth: 400, gaplessPlayback: true),
      );
    } else if (remote != null && remote.error.isNotEmpty) {
      child = InkWell(
        onTap: () => AppState.instance.retryChatImage(pcId, sessionId, imageId),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.broken_image_outlined, color: Ember.text3),
            const SizedBox(height: 4),
            Text('${remote.error}\nTap to retry',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Ember.text3)),
          ],
        ),
      );
    } else {
      child = const Center(
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: Ember.surface3,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Ember.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// A picture in full, with pinch to zoom.
class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: const GlassTopBar(title: Text('Picture')),
      body: SafeArea(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
        ),
      ),
    );
  }
}

/// A message as plain text that can be selected piece by piece.
class _SelectTextScreen extends StatelessWidget {
  const _SelectTextScreen({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassTopBar(
        title: const Text('Select text'),
        actions: [
          GhostIconButton(
            icon: Icons.copy_all_rounded,
            tooltip: 'Copy all',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
        ],
      ),
      body: EmberBackground(
        animate: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: SelectableText(text, style: Theme.of(context).textTheme.bodyLarge),
        ),
      ),
    );
  }
}

/// One tool call as a quiet line on the rail; tap to show it in full.
class _ToolLine extends StatelessWidget {
  const _ToolLine({super.key, required this.item, required this.expanded, required this.onTap});

  final ChatItem item;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tool = item.tool.isEmpty ? 'Tool' : item.tool;
    final detail = item.text == item.tool ? '' : item.text;
    return PressScale(
      scale: 0.99,
      haptic: false,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 3, 2, 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Icon(Icons.terminal_rounded, size: 13, color: Ember.text3),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: tool,
                      style: const TextStyle(fontWeight: FontWeight.w600, color: Ember.text2),
                    ),
                    if (detail.isNotEmpty)
                      TextSpan(
                        text: '  $detail',
                        style: TextStyle(fontFamily: Ember.mono(context), color: Ember.text3),
                      ),
                  ],
                ),
                style: const TextStyle(fontSize: 12.5, height: 1.4),
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
  const _ToolGroup({super.key, required this.items, required this.expanded, required this.onToggle});

  final List<ChatItem> items;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final names = <String>[];
    for (final it in items) {
      final n = it.tool.isEmpty ? 'Tool' : it.tool;
      if (!names.contains(n)) names.add(n);
    }
    const style = TextStyle(color: Ember.text3, fontSize: 12.5, height: 1.4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PressScale(
          scale: 0.99,
          haptic: false,
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
            child: Row(
              children: [
                const Icon(Icons.terminal_rounded, size: 13, color: Ember.text3),
                const SizedBox(width: 8),
                Text('${items.length} tool calls',
                    style: style.copyWith(fontWeight: FontWeight.w600, color: Ember.text2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(names.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: Motion.base,
                  curve: Motion.emphasized,
                  child: const Icon(Icons.expand_more_rounded, size: 18, color: Ember.text3),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: Motion.base,
          curve: Motion.easeOut,
          alignment: Alignment.topCenter,
          child: expanded
              ? Container(
                  margin: const EdgeInsets.fromLTRB(8, 2, 0, 6),
                  padding: const EdgeInsets.only(left: 10),
                  decoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: Ember.lineStrong, width: 1.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final it in items) _ToolLine(item: it, expanded: true, onTap: null),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// A pending request of the session (permission / question / plan) with quick
/// answers; tapping the card body opens the full answer screen.
class _RequestCard extends StatelessWidget {
  const _RequestCard({
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
    final t = Theme.of(context).textTheme;
    final color = Ember.requestColor(r.kind);
    final title = r.title.isEmpty ? AnswerScreen.kindLabel(r.kind) : r.title;
    final summary = r.summary.isNotEmpty ? r.summary : r.detail;
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      glow: sending ? null : color,
      borderColor: color.withValues(alpha: sending ? 0.25 : 0.5),
      fill: Ember.surface2.withValues(alpha: 0.92),
      onTap: onOpen,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Hero(
                tag: 'request:${entry.key}',
                child: IconTile(icon: AnswerScreen.iconFor(r.kind), color: color, size: 34, iconSize: 17),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
                        ),
                        Text(AnswerScreen.kindLabel(r.kind), style: t.labelSmall?.copyWith(color: color)),
                      ],
                    ),
                    if (summary.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(
                            color: Ember.text2,
                            fontFamily: r.kind == RequestKind.permission ? Ember.mono(context) : null,
                            fontSize: r.kind == RequestKind.permission ? 12.5 : 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              Tooltip(
                message: r.kind == RequestKind.question && r.questions.length > 1 ? 'Copy the questions' : 'Copy',
                child: InkResponse(
                  radius: 18,
                  onTap: () => AnswerScreen.copy(context, r),
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(6, 6, 4, 6),
                    child: Icon(Icons.copy_rounded, size: 17, color: Ember.text3),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 7),
                child: Icon(Icons.chevron_right_rounded, size: 20, color: Ember.text3),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: Motion.base,
            transitionBuilder: fadeUpTransition,
            child: sending ? _sendingRow(context) : _actions(context, r),
          ),
        ],
      ),
    );
  }

  Widget _sendingRow(BuildContext context) {
    return Padding(
      key: const ValueKey<String>('sending'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: Ember.amber),
          ),
          const SizedBox(width: 10),
          Text(
            'Sending your answer…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Ember.text2),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, CcRequest r) {
    final List<Widget> buttons;
    switch (r.kind) {
      case RequestKind.plan:
        buttons = <Widget>[
          EmberButton(
            label: 'Approve',
            icon: Icons.check_rounded,
            small: true,
            onPressed: () => onAnswer(Answers.approve()),
          ),
          EmberButton(
            label: 'Reject',
            small: true,
            style: EmberButtonStyle.danger,
            onPressed: () => onAnswer(Answers.reject()),
          ),
          EmberButton(label: 'Read plan', small: true, style: EmberButtonStyle.ghost, onPressed: onOpen),
        ];
        break;
      case RequestKind.question:
        final q = _singleQuestion(r);
        if (q == null) {
          buttons = <Widget>[
            EmberButton(label: 'Answer', icon: Icons.edit_rounded, small: true, style: EmberButtonStyle.blue, onPressed: onOpen),
          ];
        } else {
          buttons = <Widget>[
            for (final o in q.options)
              EmberButton(
                label: o.label,
                small: true,
                style: EmberButtonStyle.secondary,
                onPressed: () => onAnswer(Answers.questions(<String, String>{q.question: o.label})),
              ),
            EmberButton(label: 'Other…', small: true, style: EmberButtonStyle.ghost, onPressed: onOpen),
          ];
        }
        break;
      default: // permission
        buttons = <Widget>[
          EmberButton(
            label: 'Allow',
            icon: Icons.check_rounded,
            small: true,
            onPressed: () => onAnswer(Answers.allow()),
          ),
          if (r.canAllowAlways)
            EmberButton(
              label: 'Always',
              small: true,
              style: EmberButtonStyle.secondary,
              onPressed: () => onAnswer(Answers.allowAlways()),
            ),
          EmberButton(
            label: 'Deny',
            small: true,
            style: EmberButtonStyle.danger,
            onPressed: () => onAnswer(Answers.deny()),
          ),
        ];
    }
    return Wrap(key: const ValueKey<String>('actions'), spacing: 8, runSpacing: 8, children: buttons);
  }
}

/// What the session made with Claude's Artifact tool (v1.6): designs,
/// documents, pages. Tap to open it on the phone; hold to copy the link.
class _ArtifactStrip extends StatefulWidget {
  const _ArtifactStrip({required this.artifacts, required this.onOpen, required this.onCopy});

  final List<SessionArtifact> artifacts;
  final Future<void> Function(SessionArtifact artifact) onOpen;
  final void Function(String url) onCopy;

  static (IconData, Color) look(String kind) {
    switch (kind) {
      case 'design':
        return (Icons.brush_rounded, Ember.amber);
      case 'document':
        return (Icons.article_outlined, Ember.mewoSoft);
      case 'page':
        return (Icons.web_rounded, Ember.ok);
      default:
        return (Icons.auto_awesome_rounded, Ember.text2);
    }
  }

  @override
  State<_ArtifactStrip> createState() => _ArtifactStripState();
}

class _ArtifactStripState extends State<_ArtifactStrip> {
  static const int _fold = 2;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // Newest first.
    final all = widget.artifacts.reversed.toList();
    final shown = _expanded ? all : all.take(_fold).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown.length; i++)
          FadeSlideIn(
            key: ValueKey<String>(shown[i].url),
            delay: Motion.stagger(i, step: 50),
            offset: const Offset(0, 10),
            child: _ArtifactRow(
              artifact: shown[i],
              onTap: () => widget.onOpen(shown[i]),
              onLongPress: () => widget.onCopy(shown[i].url),
            ),
          ),
        if (all.length > _fold)
          Align(
            alignment: Alignment.centerLeft,
            child: PressScale(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  _expanded ? 'Show less' : 'Show ${all.length - _fold} more',
                  style: t.labelMedium?.copyWith(color: Ember.text2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({required this.artifact, required this.onTap, required this.onLongPress});

  final SessionArtifact artifact;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final (icon, color) = _ArtifactStrip.look(artifact.kind);
    final title = artifact.title.isEmpty ? 'Claude ${artifact.kindLabel.toLowerCase()}' : artifact.title;
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      radius: 14,
      fill: Ember.surface2.withValues(alpha: 0.92),
      borderColor: color.withValues(alpha: 0.35),
      glow: artifact.kind == 'design' ? color : null,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Row(
        children: [
          IconTile(icon: icon, color: color, size: 34, iconSize: 17),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall?.copyWith(fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(
                  '${artifact.kindLabel} · made by Claude${artifact.ts > 0 ? ' · ${_clock(artifact.ts)}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelSmall?.copyWith(color: Ember.text3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(artifact.local ? Icons.visibility_rounded : Icons.open_in_new_rounded, size: 13, color: color),
                const SizedBox(width: 5),
                Text(artifact.local ? 'View' : 'Open', style: t.labelMedium?.copyWith(color: color, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The open pull requests of the session's repository (v1.6), pinned above
/// the input like Claude Desktop's: number, repository, branch, the size of
/// the change and whether CI is green. Tap one for its checks and links; the
/// × hides it until the chat is opened again.
class _PrStrip extends StatefulWidget {
  const _PrStrip({required this.list, required this.onOpen});

  final PrList list;
  final void Function(PullRequest pr) onOpen;

  static Color colorOf(String state) {
    switch (state) {
      case 'pass':
        return Ember.ok;
      case 'fail':
        return Ember.danger;
      case 'pending':
        return Ember.amber;
      default:
        return Ember.text2;
    }
  }

  /// Errors that are just "this is not that kind of session": no note.
  static bool quiet(String error) =>
      error.isEmpty || error.startsWith('Not a git') || error.contains('folder is not on');

  @override
  State<_PrStrip> createState() => _PrStripState();
}

class _PrStripState extends State<_PrStrip> {
  static const int _fold = 2;
  bool _expanded = false;
  final Set<int> _hidden = <int>{};

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    final prs = <PullRequest>[
      for (final p in list.prs)
        if (!_hidden.contains(p.number)) p,
    ];
    final t = Theme.of(context).textTheme;
    Widget child;
    if (prs.isEmpty) {
      child = (list.loaded && !_PrStrip.quiet(list.error) && list.error.isNotEmpty)
          ? Padding(
              key: const ValueKey<String>('pr-error'),
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.call_merge_rounded, size: 14, color: Ember.text3),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Pull requests: ${list.error}', style: t.labelSmall?.copyWith(color: Ember.text3)),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(key: ValueKey<String>('pr-none'));
    } else {
      final shown = _expanded ? prs : prs.take(_fold).toList();
      child = Column(
        key: const ValueKey<String>('pr-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < shown.length; i++)
            FadeSlideIn(
              key: ValueKey<int>(shown[i].number),
              delay: Motion.stagger(i, step: 50),
              offset: const Offset(0, 10),
              child: _PrRow(
                pr: shown[i],
                repo: list.repo,
                onTap: () => widget.onOpen(shown[i]),
                onHide: () => setState(() => _hidden.add(shown[i].number)),
              ),
            ),
          if (prs.length > _fold)
            Align(
              alignment: Alignment.centerLeft,
              child: PressScale(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    _expanded ? 'Show less' : 'Show ${prs.length - _fold} more',
                    style: t.labelMedium?.copyWith(color: Ember.text2),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return AnimatedSize(
      duration: Motion.base,
      curve: Motion.easeOut,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: Motion.base,
        transitionBuilder: fadeUpTransition,
        child: child,
      ),
    );
  }
}

class _PrRow extends StatelessWidget {
  const _PrRow({required this.pr, required this.repo, required this.onTap, required this.onHide});

  final PullRequest pr;
  final String repo;
  final VoidCallback onTap;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = _PrStrip.colorOf(pr.ci);
    final name = repo.contains('/') ? repo.substring(repo.indexOf('/') + 1) : repo;
    final mono = Ember.mono(context);
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 7, 4, 8),
      radius: 14,
      fill: Ember.surface2.withValues(alpha: 0.92),
      borderColor: pr.ci == 'fail'
          ? Ember.danger.withValues(alpha: 0.4)
          : pr.current
              ? Ember.amber.withValues(alpha: 0.35)
              : null,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.call_merge_rounded, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                '#${pr.number}',
                style: t.labelMedium?.copyWith(color: Ember.text2, fontFamily: mono, fontSize: 12.5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name.isEmpty ? pr.title : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleSmall?.copyWith(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              _Diff(additions: pr.additions, deletions: pr.deletions),
              if (pr.ci != 'none') ...[
                const SizedBox(width: 8),
                _CiChip(state: pr.ci),
              ],
              GhostIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Hide this pull request here',
                filled: false,
                size: 30,
                iconSize: 15,
                onPressed: onHide,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    pr.branch,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelSmall?.copyWith(
                      color: Ember.text3,
                      fontFamily: mono,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (pr.draft)
                  Text('Draft', style: t.labelSmall?.copyWith(color: Ember.text3))
                else if (pr.review.isNotEmpty)
                  Text(
                    pr.review == 'approved'
                        ? 'Approved'
                        : pr.review == 'changes'
                            ? 'Changes requested'
                            : 'Review needed',
                    style: t.labelSmall?.copyWith(
                      color: pr.review == 'approved'
                          ? Ember.ok
                          : pr.review == 'changes'
                              ? Ember.danger
                              : Ember.text3,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `+87 −0`.
class _Diff extends StatelessWidget {
  const _Diff({required this.additions, required this.deletions, this.size = 12});
  final int additions;
  final int deletions;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: Ember.mono(context),
      fontSize: size,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '+$additions', style: style.copyWith(color: Ember.ok)),
        TextSpan(text: ' −$deletions', style: style.copyWith(color: Ember.danger)),
      ]),
    );
  }
}

class _CiChip extends StatelessWidget {
  const _CiChip({required this.state});
  final String state;

  @override
  Widget build(BuildContext context) {
    final color = _PrStrip.colorOf(state);
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 8, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == 'pending')
            SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.5, color: color))
          else
            Icon(state == 'pass' ? Icons.check_rounded : Icons.close_rounded, size: 11, color: color),
          const SizedBox(width: 4),
          Text('CI', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontSize: 10.5)),
        ],
      ),
    );
  }
}

class _ReviewPill extends StatelessWidget {
  const _ReviewPill({required this.review});
  final String review;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (review) {
      'approved' => ('Approved', Ember.ok),
      'changes' => ('Changes requested', Ember.danger),
      _ => ('Review needed', Ember.amber),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 3, 9, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text, required this.onRetry});

  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        radius: 16,
        fill: const Color(0xFF2A1618).withValues(alpha: 0.94),
        borderColor: Ember.danger.withValues(alpha: 0.45),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_rounded, size: 18, color: Ember.danger),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Ember.text)),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// The owner's self-check (policy Checklist F) and the scan of the
/// session's changes (v1.7), on the pull request sheet.
class _SelfCheck extends StatefulWidget {
  const _SelfCheck({required this.pcId, required this.sessionId});

  final String pcId;
  final String sessionId;

  @override
  State<_SelfCheck> createState() => _SelfCheckState();
}

class _SelfCheckState extends State<_SelfCheck> {
  final AppState _state = AppState.instance;
  bool _scanning = false;
  bool _review = false;

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      await _state.scan(widget.pcId, widget.sessionId);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final t = Theme.of(context).textTheme;
        final session = _state.findSession(widget.pcId, widget.sessionId)?.session;
        final data = _state.featuresOf(widget.pcId);
        final lines = (data?.selfCheck.isNotEmpty ?? false) ? data!.selfCheck : kSelfCheck;
        final review = (data?.reviewCheck.isNotEmpty ?? false) ? data!.reviewCheck : kReviewCheck;
        final checks = session?.checks ?? const <bool>[];
        final done = checks.where((c) => c).length;
        final scan = _state.scanOf(widget.pcId, widget.sessionId);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 18),
            Row(
              children: [
                Text('SELF-CHECK · CHECKLIST F', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.4)),
                const Spacer(),
                Text('$done/${lines.length}', style: t.labelSmall?.copyWith(color: done == lines.length ? Ember.ok : Ember.text3)),
              ],
            ),
            const SizedBox(height: 8),
            GlassCard(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
              radius: 16,
              fill: Ember.surface2.withValues(alpha: 0.8),
              child: Column(
                children: [
                  for (var i = 0; i < lines.length; i++)
                    CheckboxListTile(
                      value: i < checks.length && checks[i],
                      onChanged: (v) {
                        HapticFeedback.selectionClick();
                        _state.setCheck(widget.pcId, widget.sessionId, i, v ?? false);
                      },
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      activeColor: Ember.ok,
                      title: Text(lines[i], style: t.bodySmall?.copyWith(color: Ember.text, fontSize: 12.5)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (scan != null && scan.ok) ...[
              Row(
                children: [
                  Icon(scan.findings.isEmpty ? Icons.check_circle_outline_rounded : Icons.search_rounded, size: 16, color: scan.findings.isEmpty ? Ember.ok : Ember.amber),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      scan.findings.isEmpty
                          ? 'Nothing found against ${scan.base}: ${scan.files} files, +${scan.additions} −${scan.deletions}.'
                          : '${scan.findings.length} finding${scan.findings.length == 1 ? '' : 's'} against ${scan.base}: ${scan.counts.map((c) => '${c.$2} ${c.$1.toLowerCase()}').join(', ')}.',
                      style: t.bodySmall?.copyWith(color: Ember.text2),
                    ),
                  ),
                ],
              ),
              for (final f in scan.findings.take(6))
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 22),
                  child: Text(
                    '${f.file}${f.line > 0 ? ':${f.line}' : ''} · ${f.text}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelSmall?.copyWith(color: Ember.text3, fontFamily: Ember.mono(context), fontWeight: FontWeight.w400, letterSpacing: 0),
                  ),
                ),
              if (scan.findings.length > 6)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 22),
                  child: Text('+${scan.findings.length - 6} more on the console', style: t.labelSmall?.copyWith(color: Ember.text3)),
                ),
              const SizedBox(height: 10),
            ] else if (scan != null && scan.error.isNotEmpty) ...[
              Text('Scan: ${scan.error}', style: t.bodySmall?.copyWith(color: Ember.text3)),
              const SizedBox(height: 10),
            ],
            EmberButton(
              label: scan == null ? 'Scan my changes for slop' : 'Scan again',
              icon: Icons.search_rounded,
              style: EmberButtonStyle.secondary,
              expand: true,
              busy: _scanning,
              onPressed: _scanning ? null : _scan,
            ),
            const SizedBox(height: 14),
            PressScale(
              onTap: () => setState(() => _review = !_review),
              child: Row(
                children: [
                  Text('REVIEW · CHECKLISTS G AND H', style: t.labelSmall?.copyWith(color: Ember.text3, letterSpacing: 1.4)),
                  const Spacer(),
                  Icon(_review ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: Ember.text3),
                ],
              ),
            ),
            if (_review) ...[
              const SizedBox(height: 6),
              Text('By another developer, never the session owner.', style: t.labelSmall?.copyWith(color: Ember.text3)),
              const SizedBox(height: 6),
              for (final line in review)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(padding: EdgeInsets.only(top: 3), child: Icon(Icons.circle, size: 5, color: Ember.amber)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(line, style: t.bodySmall?.copyWith(color: Ember.text2, fontSize: 12.5))),
                    ],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}
