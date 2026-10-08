import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../models.dart';
import 'theme/ember.dart';
import 'theme/flame.dart';
import 'theme/glass.dart';
import 'theme/motion.dart';

/// What a session made, shown in place (v1.6): the PC sends the daemon's
/// copy of the files. A design shows board by board and a page as is, in
/// a web view; a document as markdown in the app's own style.
class ArtifactScreen extends StatefulWidget {
  const ArtifactScreen({super.key, required this.pcId, required this.sessionId, required this.artifact});

  final String pcId;
  final String sessionId;
  final SessionArtifact artifact;

  @override
  State<ArtifactScreen> createState() => _ArtifactScreenState();
}

class _Board {
  const _Board({required this.file, required this.title, required this.w, required this.h});

  /// Path inside the bundle.
  final String file;
  final String title;
  final double w;
  final double h;
}

class _ArtifactScreenState extends State<ArtifactScreen> {
  final AppState _state = AppState.instance;
  ArtifactBundle? _bundle;
  String _error = '';
  List<_Board> _boards = const <_Board>[];
  int _board = 0;
  String _markdown = '';
  WebViewController? _web;
  bool _webReady = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = '';
      _bundle = null;
      _web = null;
      _webReady = false;
    });
    try {
      final bundle = await _state.fetchArtifact(widget.pcId, widget.sessionId, widget.artifact);
      if (!mounted) return;
      await _show(bundle);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is StateError ? e.message : 'Could not load it');
    }
  }

  Future<void> _show(ArtifactBundle b) async {
    final entry = b.entry;
    if (entry.endsWith('.md')) {
      String text;
      try {
        text = await File('${b.dir}/$entry').readAsString();
      } catch (_) {
        text = '';
      }
      if (!mounted) return;
      setState(() {
        _bundle = b;
        _markdown = text;
      });
      return;
    }
    var boards = <_Board>[];
    var first = entry;
    if (entry.endsWith('canvas.json')) {
      final dir = entry.substring(0, entry.length - 'canvas.json'.length);
      try {
        final canvas = jsonDecode(await File('${b.dir}/$entry').readAsString());
        final specs = canvas is Map ? canvas['boards'] : null;
        final order = canvas is Map && canvas['order'] is List
            ? (canvas['order'] as List).map((e) => '$e').toList()
            : (specs is Map ? specs.keys.map((e) => '$e').toList() : const <String>[]);
        for (final f in order) {
          final s = specs is Map ? specs[f] : null;
          boards.add(_Board(
            file: '$dir$f',
            title: s is Map && s['title'] is String && (s['title'] as String).isNotEmpty ? s['title'] as String : f.replaceAll('.dc.html', ''),
            w: s is Map && s['w'] is num ? (s['w'] as num).toDouble() : 390,
            h: s is Map && s['h'] is num ? (s['h'] as num).toDouble() : 844,
          ));
        }
      } catch (_) {}
      if (boards.isEmpty) {
        setState(() => _error = 'This design has no boards yet');
        return;
      }
      first = boards.first.file;
    } else if (entry.endsWith('.dc.html')) {
      boards = <_Board>[_Board(file: entry, title: widget.artifact.title, w: 390, h: 844)];
    }
    final web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Ember.bg)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _webReady = true);
        },
        onNavigationRequest: (req) {
          final u = req.url;
          if (u.startsWith('file://') || u.startsWith('about:')) {
            _syncBoard(u);
            return NavigationDecision.navigate;
          }
          final uri = Uri.tryParse(u);
          if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
      ));
    setState(() {
      _bundle = b;
      _boards = boards;
      _board = 0;
      _web = web;
    });
    await web.loadFile('${b.dir}/$first');
  }

  /// A link inside a board to another board moves the chips along.
  void _syncBoard(String url) {
    final decoded = Uri.decodeFull(url);
    final i = _boards.indexWhere((b) => decoded.endsWith('/${b.file}'));
    if (i >= 0 && i != _board && mounted) setState(() => _board = i);
  }

  Future<void> _showBoard(int i) async {
    final b = _bundle;
    final web = _web;
    if (b == null || web == null || i == _board) return;
    HapticFeedback.selectionClick();
    setState(() {
      _board = i;
      _webReady = false;
    });
    await web.loadFile('${b.dir}/${_boards[i].file}');
  }

  Future<void> _openOnline() async {
    final uri = Uri.tryParse(widget.artifact.url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.artifact;
    final title = a.title.isEmpty ? 'Claude ${a.kindLabel.toLowerCase()}' : a.title;
    return Scaffold(
      backgroundColor: Ember.bg,
      appBar: GlassTopBar(
        title: Text(title),
        subtitle: Text('${a.kindLabel} · ${_state.pcNameFor(widget.pcId)}'),
        actions: [
          GhostIconButton(icon: Icons.open_in_new_rounded, tooltip: 'Open on claude.ai', onPressed: _openOnline),
        ],
      ),
      body: EmberBackground(
        animate: false,
        child: AnimatedSwitcher(
          duration: Motion.base,
          transitionBuilder: fadeUpTransition,
          child: _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (_error.isNotEmpty) return _message(context, icon: Icons.cloud_off_rounded, text: _error, retry: true);
    final b = _bundle;
    if (b == null) {
      return Center(
        key: const ValueKey<String>('loading'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: Ember.amber)),
            const SizedBox(height: 14),
            Text('Fetching from ${_state.pcNameFor(widget.pcId)}…', style: t.bodySmall?.copyWith(color: Ember.text2)),
          ],
        ),
      );
    }
    if (b.entry.endsWith('.md')) return _document(context);
    final web = _web;
    if (web == null) return const SizedBox.shrink();
    return Column(
      key: const ValueKey<String>('web'),
      children: [
        if (_boards.length > 1)
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              itemCount: _boards.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => _chip(context, _boards[i].title, selected: i == _board, onTap: () => _showBoard(i)),
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: WebViewWidget(controller: web)),
              if (!_webReady)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Ember.bg,
                    child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Ember.amber))),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, {required bool selected, required VoidCallback onTap}) {
    final t = Theme.of(context).textTheme;
    return PressScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.base,
        curve: Motion.easeOut,
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        decoration: BoxDecoration(
          color: selected ? Ember.amber.withValues(alpha: 0.14) : Ember.surface2.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? Ember.amber.withValues(alpha: 0.7) : Ember.line),
        ),
        child: Center(child: Text(label, style: t.labelLarge?.copyWith(fontSize: 13, color: selected ? Ember.amber : Ember.text))),
      ),
    );
  }

  Widget _document(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final mono = Ember.mono(context);
    final sheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: t.bodyMedium?.copyWith(fontSize: 15, height: 1.55),
      h1: t.headlineSmall,
      h2: t.titleLarge,
      h3: t.titleMedium,
      h4: t.titleSmall,
      strong: const TextStyle(fontWeight: FontWeight.w700, color: Ember.text),
      em: const TextStyle(fontStyle: FontStyle.italic),
      listBullet: t.bodyMedium?.copyWith(color: Ember.amber),
      a: t.bodyMedium?.copyWith(color: Ember.mewoSoft, decoration: TextDecoration.underline),
      code: TextStyle(fontFamily: mono, fontSize: 13, color: Ember.gold, backgroundColor: Ember.codeBg),
      codeblockDecoration: BoxDecoration(
        color: Ember.codeBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Ember.line),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockquote: t.bodyMedium?.copyWith(color: Ember.text2),
      blockquoteDecoration: const BoxDecoration(border: Border(left: BorderSide(color: Ember.ember, width: 3))),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      horizontalRuleDecoration: const BoxDecoration(border: Border(top: BorderSide(color: Ember.line))),
      tableBorder: TableBorder.all(color: Ember.line, borderRadius: BorderRadius.circular(8)),
      tableHead: t.labelLarge,
      tableBody: t.bodySmall?.copyWith(color: Ember.text),
      tableCellsPadding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
    );
    return ListView(
      key: const ValueKey<String>('doc'),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        if (_markdown.trim().isEmpty)
          Text('This document is empty.', style: t.bodyMedium?.copyWith(color: Ember.text2))
        else
          MarkdownBody(
            data: _markdown,
            selectable: true,
            styleSheet: sheet,
            onTapLink: (text, href, title) {
              final uri = href == null ? null : Uri.tryParse(href);
              if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
            },
          ),
      ],
    );
  }

  Widget _message(BuildContext context, {required IconData icon, required String text, bool retry = false}) {
    final t = Theme.of(context).textTheme;
    return Center(
      key: ValueKey<String>('msg:$text'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTile(icon: icon, color: Ember.text2, size: 52, iconSize: 26),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: Ember.text2)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                if (retry) EmberButton(label: 'Try again', icon: Icons.refresh_rounded, onPressed: _load),
                EmberButton(label: 'Open on claude.ai', icon: Icons.open_in_new_rounded, onPressed: _openOnline),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
