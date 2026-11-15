import "package:markdown/markdown.dart" as md;

final descriptionMarkdownExtensions = md.ExtensionSet(
  [
    const _HtmlBreakBlockSyntax(),
    ...md.ExtensionSet.gitHubFlavored.blockSyntaxes,
  ],
  [_HtmlBreakSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
);

class _HtmlBreakSyntax extends md.InlineSyntax {
  _HtmlBreakSyntax() : super(r"<br[ \t]*/?>", caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty("br"));
    return true;
  }
}

class _HtmlBreakBlockSyntax extends md.BlockSyntax {
  const _HtmlBreakBlockSyntax();

  @override
  RegExp get pattern =>
      RegExp(r"^[ \t]{0,3}(?:<br[ \t]*/?>[ \t]*)+$", caseSensitive: false);

  @override
  md.Node? parse(md.BlockParser parser) {
    parser.advance();
    return null;
  }
}

String descriptionPreview(String text, {int? maxLength}) {
  final nodes = md.Document(
    extensionSet: descriptionMarkdownExtensions,
    encodeHtml: false,
  ).parseLines(text.replaceAll("\r\n", "\n").split("\n"));
  final buffer = StringBuffer();

  void append(md.Node node) {
    if (node is md.Text) {
      buffer.write(node.text);
    } else if (node is md.Element) {
      if (node.tag == "img") buffer.write(node.attributes["alt"] ?? "");
      for (final child in node.children ?? <md.Node>[]) {
        append(child);
      }
      if ({
        "br",
        "p",
        "li",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "pre",
        "td",
        "th",
      }.contains(node.tag)) {
        buffer.write(" ");
      }
    }
  }

  for (final node in nodes) {
    append(node);
  }
  final normalized = buffer.toString().replaceAll(RegExp(r"\s+"), " ").trim();
  if (maxLength == null || normalized.runes.length <= maxLength) {
    return normalized;
  }
  return "${String.fromCharCodes(normalized.runes.take(maxLength))}...";
}
