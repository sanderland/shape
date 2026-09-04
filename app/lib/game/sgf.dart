// Small FF[4] SGF parser used by the game importer.
//
// It parses the complete node and variation grammar and leaves game-specific
// checks, such as supported board sizes and setup stones, to ShapeGame.

class SgfFormatException implements Exception {
  final String message;
  const SgfFormatException(this.message);

  @override
  String toString() => message;
}

class SgfNode {
  final Map<String, List<String>> properties;
  final List<SgfNode> children = [];

  SgfNode(this.properties);

  String? value(String name) {
    final values = properties[name];
    return values == null || values.isEmpty ? null : values.first;
  }
}

SgfNode parseSgf(String source) => _SgfParser(source).parse();

class _SgfParser {
  final String source;
  int index = 0;

  _SgfParser(this.source);

  SgfNode parse() {
    _skipWhitespace();
    final start = RegExp(r'\(\s*;').firstMatch(source.substring(index));
    if (start == null) {
      throw const SgfFormatException('The SGF is empty');
    }
    index += start.start;
    final root = _gameTree();
    _skipWhitespace();
    if (index != source.length) {
      throw _error('Only one game per SGF file is supported');
    }
    return root;
  }

  SgfNode _gameTree() {
    _expect('(');
    _skipWhitespace();
    if (!_at(';')) throw _error('Expected an SGF node');

    final first = _node();
    var tail = first;
    _skipWhitespace();
    while (_at(';')) {
      final next = _node();
      tail.children.add(next);
      tail = next;
      _skipWhitespace();
    }
    while (_at('(')) {
      tail.children.add(_gameTree());
      _skipWhitespace();
    }
    _expect(')');
    return first;
  }

  SgfNode _node() {
    _expect(';');
    final properties = <String, List<String>>{};
    _skipWhitespace();
    while (index < source.length && _isLetter(source.codeUnitAt(index))) {
      final name = _identifier();
      _skipWhitespace();
      if (!_at('[')) throw _error('Property $name has no value');
      final values = <String>[];
      while (_at('[')) {
        values.add(_propertyValue());
        _skipWhitespace();
      }
      properties.putIfAbsent(name, () => []).addAll(values);
    }
    return SgfNode(properties);
  }

  String _identifier() {
    final start = index;
    while (index < source.length) {
      final c = source.codeUnitAt(index);
      if (!_isLetter(c) && (c < 48 || c > 57)) break;
      index++;
    }
    return source.substring(start, index).toUpperCase();
  }

  String _propertyValue() {
    _expect('[');
    final value = StringBuffer();
    while (index < source.length) {
      final c = source[index++];
      if (c == ']') return value.toString();
      if (c != r'\') {
        if (c == '\n' || c == '\r') {
          if (index < source.length &&
              ((c == '\n' && source[index] == '\r') ||
                  (c == '\r' && source[index] == '\n'))) {
            index++;
          }
          value.write('\n');
          continue;
        }
        value.write(c);
        continue;
      }
      if (index >= source.length) {
        throw _error('Unfinished escape in property value');
      }
      final escaped = source[index++];
      if (escaped == '\n') {
        if (index < source.length && source[index] == '\r') index++;
        continue;
      }
      if (escaped == '\r') {
        if (index < source.length && source[index] == '\n') index++;
        continue;
      }
      value.write(escaped);
    }
    throw _error('Unclosed property value');
  }

  void _skipWhitespace() {
    while (index < source.length) {
      final c = source.codeUnitAt(index);
      if (c != 9 && c != 10 && c != 13 && c != 32) return;
      index++;
    }
  }

  bool _at(String c) => index < source.length && source[index] == c;

  void _expect(String c) {
    if (!_at(c)) throw _error('Expected "$c"');
    index++;
  }

  bool _isLetter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

  SgfFormatException _error(String message) {
    final end = index.clamp(0, source.length);
    final line = '\n'.allMatches(source.substring(0, end)).length + 1;
    return SgfFormatException('$message at line $line');
  }
}
