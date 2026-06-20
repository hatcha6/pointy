/// A deep link the AI assistant emits inside its markdown so the user can jump
/// straight to a page — a top-level screen or a specific record's detail.
///
/// Wire format (in a markdown link `[text](...)`):
///   - `pointy://screen/<key>`        → a top-level screen (key = a screen id)
///   - `pointy://<type>/<id>`         → an entity detail (e.g. product/42)
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
