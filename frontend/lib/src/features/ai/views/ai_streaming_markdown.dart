import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// How a streamed reply arrives on screen: word by word, each word fading in a
/// beat after the one before it — the cascade ChatGPT uses — instead of text
/// snapping in whole network chunks at a time.
///
/// Mechanics, mirroring ChatGPT's renderer:
/// * every word gets a start time on one shared timeline, [wordStagger] after
///   the previous word, but never more than [maxLag] in the future — so a large
///   burst compresses into a quick sweep instead of trailing the network;
/// * a word that has not started yet is not shown at all (the text is cut just
///   before it), a started word fades from transparent over [fadeDuration], and
///   a finished word is plain text again;
/// * once every word has settled the reply renders exactly as it always did,
///   memoized, with no animation cost — a settled word never animates again.
///
/// Reduced motion (the platform's "disable animations") turns all of it off.
abstract final class AiStreamingReveal {
  static const Duration fadeDuration = Duration(milliseconds: 420);
  static const Duration wordStagger = Duration(milliseconds: 24);
  static const Duration maxLag = Duration(milliseconds: 480);
}

/// Private-use marker characters wrapped around a word that is mid-fade.
/// `\uE000` + two-digit opacity + `\uE001` + word + `\uE002`.
const _open = '\uE000';
const _mid = '\uE001';
const _close = '\uE002';

/// Characters that make a word unsafe to wrap: wrapping it could break the
/// markdown construct it belongs to (emphasis, links, code, tables, maths).
final _unsafeWord = RegExp(r'[*_`\[\]()#|<>$~\\]');

/// A line's leading list / quote / heading marker must stay untouched or the
/// block would stop being recognised.
final _blockMarker = RegExp(r'^(\d+[.)]|[-*+>]+)$');

final _word = RegExp(r'\S+');

/// The shared start-time ledger for one reply's words.
///
/// Pure Dart (time is passed in) so it is testable without a ticker.
class WordRevealTimeline {
  final List<Duration> _starts = [];
  Duration _nextStart = Duration.zero;

  /// Words seen so far.
  int get length => _starts.length;

  /// Register the words of [content] that have not been seen yet. With
  /// [animate] false (a reply loaded from history, or reduced motion) they are
  /// registered as already settled.
  void observe(String content, Duration now, {required bool animate}) {
    final count = _word.allMatches(content).length;
    for (var i = _starts.length; i < count; i++) {
      if (!animate) {
        _starts.add(now - AiStreamingReveal.fadeDuration);
        continue;
      }
      var start = _nextStart < now ? now : _nextStart;
      final ceiling = now + AiStreamingReveal.maxLag;
      if (start > ceiling) {
        start = ceiling;
      }
      _starts.add(start);
      _nextStart = start + AiStreamingReveal.wordStagger;
    }
  }

  /// Whether every registered word has finished fading at [now].
  bool isSettled(Duration now) =>
      _starts.isEmpty || now - _starts.last >= AiStreamingReveal.fadeDuration;

  /// The word's opacity at [now], or null while it has not started.
  double? _opacity(int index, Duration now) {
    if (index >= _starts.length) {
      return 1;
    }
    final elapsed = now - _starts[index];
    if (elapsed.isNegative) {
      return null;
    }
    final t =
        elapsed.inMicroseconds / AiStreamingReveal.fadeDuration.inMicroseconds;
    return t >= 1 ? 1 : Curves.easeOut.transform(t);
  }

  /// [content] as it should be shown at [now]: cut before the first word that
  /// has not started, with every mid-fade word wrapped in opacity markers.
  String markup(String content, Duration now) {
    final buffer = StringBuffer();
    final words = _word.allMatches(content).toList(growable: false);
    var cursor = 0;
    var index = 0;
    var inFence = false;
    var lineStart = 0;
    var inlineCode = false;
    var bracketDepth = 0;
    bool unsafeLine(int start) {
      final end = content.indexOf('\n', start);
      final line = content.substring(start, end < 0 ? content.length : end);
      return line.contains('|') || line.contains(r'$');
    }

    var lineUnsafe = unsafeLine(0);

    for (final match in words) {
      // Per-line state, recomputed as the scan crosses newlines.
      final gap = content.substring(cursor, match.start);
      if (gap.contains('\n')) {
        lineStart = cursor + gap.lastIndexOf('\n') + 1;
        inlineCode = false;
        bracketDepth = 0;
        lineUnsafe = unsafeLine(lineStart);
      }
      final word = match[0]!;
      final opacity = _opacity(index, now);
      if (opacity == null) {
        break;
      }
      buffer.write(gap);
      if (word.startsWith('```')) {
        inFence = !inFence;
      }
      final firstOnLine = content
          .substring(lineStart, match.start)
          .trim()
          .isEmpty;
      final safe =
          !inFence &&
          !inlineCode &&
          bracketDepth == 0 &&
          !lineUnsafe &&
          !_unsafeWord.hasMatch(word) &&
          !(firstOnLine && _blockMarker.hasMatch(word));
      if (opacity < 1 && safe) {
        final percent = (opacity * 99).round().clamp(1, 99);
        buffer
          ..write(_open)
          ..write(percent.toString().padLeft(2, '0'))
          ..write(_mid)
          ..write(word)
          ..write(_close);
      } else {
        buffer.write(word);
      }
      // Track spans that continue past this word.
      for (final char in word.split('')) {
        if (char == '`') {
          inlineCode = !inlineCode;
        } else if (char == '[') {
          bracketDepth++;
        } else if (char == ']' && bracketDepth > 0) {
          bracketDepth--;
        }
      }
      cursor = match.end;
      index++;
    }
    if (index == words.length) {
      buffer.write(content.substring(cursor));
    }
    return buffer.toString();
  }
}

/// Renders one opacity-marked word with its ambient style at that opacity.
class _FadingWordMd extends InlineMd {
  @override
  RegExp get exp =>
      RegExp('$_open(\\d\\d)$_mid([^$_open$_mid$_close]*)$_close');

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    final opacity = (int.tryParse(match?[1] ?? '') ?? 99) / 99;
    final style = config.style ?? DefaultTextStyle.of(context).style;
    final color = style.color ?? DefaultTextStyle.of(context).style.color;
    return TextSpan(
      text: match?[2] ?? '',
      style: style.copyWith(color: color?.withValues(alpha: color.a * opacity)),
    );
  }
}

final List<MarkdownComponent> _inlineComponents = [
  _FadingWordMd(),
  ...MarkdownComponent.inlineComponents,
];

/// The assistant's markdown, revealing new words with [AiStreamingReveal]
/// while [streaming], and memoized once settled so a finished reply never
/// re-parses on an unrelated rebuild.
class AiStreamingMarkdown extends StatefulWidget {
  const AiStreamingMarkdown({
    super.key,
    required this.text,
    required this.streaming,
    required this.style,
    required this.onLinkTap,
  });

  final String text;
  final bool streaming;
  final TextStyle style;
  final void Function(String url, String title) onLinkTap;

  @override
  State<AiStreamingMarkdown> createState() => _AiStreamingMarkdownState();
}

class _AiStreamingMarkdownState extends State<AiStreamingMarkdown>
    with SingleTickerProviderStateMixin {
  final WordRevealTimeline _timeline = WordRevealTimeline();
  final Stopwatch _clock = Stopwatch()..start();
  late final Ticker _ticker = createTicker((_) => _onTick());

  Widget? _cached;
  String? _cachedText;
  TextStyle? _cachedStyle;
  TextDirection? _cachedDirection;

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _onTick() {
    if (!mounted) {
      return;
    }
    if (_timeline.isSettled(_clock.elapsed)) {
      _ticker.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // Stable method reference so the memoized markdown keeps a live callback.
  void _handleLinkTap(String url, String title) => widget.onLinkTap(url, title);

  @override
  Widget build(BuildContext context) {
    final now = _clock.elapsed;
    final direction = Directionality.of(context);
    final text = widget.text;
    _timeline.observe(text, now, animate: widget.streaming && !_reduceMotion);

    if (!_timeline.isSettled(now)) {
      if (!_ticker.isActive) {
        _ticker.start();
      }
      return GptMarkdown(
        _timeline.markup(text, now),
        style: widget.style,
        textDirection: direction,
        onLinkTap: _handleLinkTap,
        inlineComponents: _inlineComponents,
      );
    }

    if (_cached == null ||
        text != _cachedText ||
        widget.style != _cachedStyle ||
        direction != _cachedDirection) {
      _cachedText = text;
      _cachedStyle = widget.style;
      _cachedDirection = direction;
      _cached = GptMarkdown(
        text,
        style: widget.style,
        textDirection: direction,
        onLinkTap: _handleLinkTap,
      );
    }
    return _cached!;
  }
}
