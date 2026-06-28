/// A deep link the AI assistant emits inside its markdown so the user can jump
/// straight to a page — a top-level screen or a specific record's detail.
///
/// Wire format (in a markdown link `[text](...)`):
///   - `pointy://screen/<key>`        → a top-level screen (key = a screen id)
///   - `pointy://<type>/<id>`         → an entity detail (e.g. product/42)
///   - `pointy://chat`                → the AI assistant itself, optionally
///     seeded: `pointy://chat/ask?prompt=<url-encoded>&send=1`. This is the one
///     link that points *into* the AI; it powers the app's proactive AI hints.
/// The `app/` host form (`pointy://app/<type>/<id>`) is accepted too, so the
/// parser is forgiving about exactly how the model phrases the authority part.
sealed class AiDeepLink {
  const AiDeepLink();

  /// Parse a link the AI emitted, or null if it isn't a recognizable `pointy://`
  /// deep link (e.g. a plain web URL — which the caller should leave alone).
  static AiDeepLink? tryParse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'pointy') {
      return null;
    }
    // Treat host + path uniformly so `pointy://product/42`, `pointy://app/product/42`
    // and `pointy:///product/42` all resolve. The conventional `app` host is just
    // a placeholder and is dropped.
    final parts = <String>[
      if (uri.host.isNotEmpty && uri.host.toLowerCase() != 'app') uri.host.toLowerCase(),
      for (final segment in uri.pathSegments)
        if (segment.trim().isNotEmpty) segment.trim(),
    ];
    if (parts.isEmpty) {
      return null;
    }
    // `pointy://chat` / `pointy://chat/ask?prompt=...&send=1` opens the AI
    // assistant, optionally pre-filling the composer with a question (and
    // auto-sending it). Handled before the two-segment guard since a bare
    // `chat` link carries its payload in the query string, not the path.
    if (parts.first.toLowerCase() == 'chat') {
      final prompt = uri.queryParameters['prompt']?.trim();
      final send = uri.queryParameters['send']?.toLowerCase();
      return AiChatLink(
        prompt: (prompt == null || prompt.isEmpty) ? null : prompt,
        autoSend: send == '1' || send == 'true',
      );
    }
    if (parts.length < 2) {
      return null;
    }
    final kind = parts[0].toLowerCase();
    final arg = parts[1];
    if (kind == 'screen') {
      return AiScreenLink(arg.toLowerCase());
    }
    final id = int.tryParse(arg);
    if (id == null || id <= 0) {
      return null;
    }
    return AiEntityLink(kind, id);
  }
}

/// A link to a top-level screen, keyed by the navigation destination's name
/// (e.g. `invoices`, `catalog`, `dashboard`).
class AiScreenLink extends AiDeepLink {
  const AiScreenLink(this.key);

  final String key;

  @override
  bool operator ==(Object other) => other is AiScreenLink && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'AiScreenLink($key)';
}

/// A link that opens the AI assistant itself. [prompt] pre-fills the composer
/// (null leaves it empty); [autoSend] sends that prompt immediately instead of
/// waiting for the user to tap send. Emitted by proactive AI hints across the
/// app — and, optionally, by the model to offer a follow-up question.
class AiChatLink extends AiDeepLink {
  const AiChatLink({this.prompt, this.autoSend = false});

  final String? prompt;
  final bool autoSend;

  @override
  bool operator ==(Object other) =>
      other is AiChatLink && other.prompt == prompt && other.autoSend == autoSend;

  @override
  int get hashCode => Object.hash(prompt, autoSend);

  @override
  String toString() => 'AiChatLink($prompt, autoSend: $autoSend)';
}

/// A link to one record's detail page (e.g. `product` 42). [type] is normalised
/// to lowercase; synonyms (sale/invoice → order, purchase/po → purchase-order)
/// are resolved where the link is opened, not here.
class AiEntityLink extends AiDeepLink {
  const AiEntityLink(this.type, this.id);

  final String type;
  final int id;

  @override
  bool operator ==(Object other) => other is AiEntityLink && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);

  @override
  String toString() => 'AiEntityLink($type, $id)';
}
