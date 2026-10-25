import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The app's legal texts. Each is a file under `assets/legal/`, one per
/// language, so a lawyer can read and change the wording without touching
/// code, and the same file can be published on the web.
enum LegalDocument {
  privacy('privacy'),
  terms('terms');

  const LegalDocument(this.file);

  final String file;

  /// The document in [language], or in Arabic when it has not been
  /// translated: the Arabic text is the one that binds.
  Future<List<LegalBlock>> load(String language, {AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    String text;
    try {
      text = await assets.loadString('assets/legal/$file.$language.md');
    } on FlutterError {
      text = await assets.loadString('assets/legal/$file.ar.md');
    }
    return LegalBlock.parse(text);
  }
}

enum LegalBlockKind { heading, bullet, paragraph }

/// One piece of a legal text: the files use a small part of Markdown, a
/// `## ` heading, a `- ` item, or a paragraph between blank lines.
class LegalBlock {
  const LegalBlock(this.kind, this.text);

  final LegalBlockKind kind;
  final String text;

  /// A line with no Arabic letter (a phone number, an address) reads left
  /// to right; set inside right-to-left text, its digit groups would be
  /// shown in reverse order.
  bool get isLatin => !RegExp(r'[\u0600-\u06FF]').hasMatch(text);

  static List<LegalBlock> parse(String source) {
    final blocks = <LegalBlock>[];
    final paragraph = <String>[];
    void flush() {
      if (paragraph.isNotEmpty) {
        blocks.add(LegalBlock(LegalBlockKind.paragraph, paragraph.join(' ')));
        paragraph.clear();
      }
    }

    for (final raw in source.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) {
        flush();
      } else if (line.startsWith('## ')) {
        flush();
        blocks.add(LegalBlock(LegalBlockKind.heading, line.substring(3)));
      } else if (line.startsWith('- ')) {
        flush();
        blocks.add(LegalBlock(LegalBlockKind.bullet, line.substring(2)));
      } else {
        paragraph.add(line);
      }
    }
    flush();
    return blocks;
  }
}
