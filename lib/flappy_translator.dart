library flappy_translator;

import 'dart:io';

import 'package:dart_style/dart_style.dart';

import 'default_settings.dart';
import 'flappy_logger.dart';
import 'parsing/csv_parser.dart';
import 'template.dart';

const String CLASS_NAME_TEMPLATE_KEY = "#CLASS_NAME#";
const String VALUES_AREA_TEMPLATE_KEY = "/// Values area";
const String FIELDS_AREA_TEMPLATE_KEY = "/// Fields area";
const String GROUPED_KEYS_AREA_TEMPLATE_KEY = "/// Grouped keys area";
const String SUPPORTED_LANGUAGES_AREA_TEMPLATE_KEY =
    "/// SupportedLanguages area";
const String PARAMETERS_REGEX = r"(\%[[0-9a-zA-Z]+]*\$(d|s))";
const List<String> RESERVED_WORDS = [
  "assert",
  "default",
  "finally",
  "rethrow",
  "try",
  "break",
  "do",
  "for",
  "return",
  "var",
  "case",
  "else",
  "if",
  "super",
  "void",
  "catch",
  "enum",
  "in",
  "switch",
  "while",
  "class",
  "extends",
  "is",
  "this",
  "with",
  "const",
  "false",
  "new",
  "throw",
  "continue",
  "final",
  "null",
  "true",
];

class FlappyTranslator {
  void generate(
    String inputFilePath, {
    String outputDir,
    String fileName,
    String className,
    String delimiter,
    int startIndex,
    bool dependOnContext,
    bool useSingleQuotes,
    bool replaceNoBreakSpaces,
    Iterable<String> groupedKey,
  }) async {
    final File file = File(inputFilePath);
    if (!file.existsSync()) {
      FlappyLogger.logError("File $inputFilePath does not exist");
      return;
    }

    // if null has been passed in, ensure that vars are given default values
    outputDir ??= DefaultSettings.outputDirectory;
    fileName ??= DefaultSettings.fileName;
    className ??= DefaultSettings.className;
    delimiter ??= DefaultSettings.delimiter;
    startIndex ??= DefaultSettings.startIndex;
    dependOnContext ??= DefaultSettings.dependOnContext;
    useSingleQuotes ??= DefaultSettings.useSingleQuotes;
    replaceNoBreakSpaces ??= DefaultSettings.replaceNoBreakSpaces;
    groupedKey ??= DefaultSettings.groupedKeys;

    // construct the template
    String template = templateBegining +
        (dependOnContext ? templateDependContext : templateDontDependContext) +
        templateEnding;
    template = template.replaceAll(CLASS_NAME_TEMPLATE_KEY, className);

    final CSVParser csvParser = CSVParser(fieldDelimiter: delimiter);

    final List<String> lines = file.readAsLinesSync();

    final List<String> supportedLanguages =
        csvParser.getSupportedLanguages(lines, startIndex: startIndex);
    final List<Map<String, String>> maps =
        _generateValuesMaps(supportedLanguages);
    final Map<String, Set<String>> groupedKeysValues =
        _generateGroupedKeysMap(groupedKey);

    template = _replaceSupportedLanguages(template, supportedLanguages);

    final String quoteString = useSingleQuotes ? '\'' : '"';
    String fields = "";
    FlappyLogger.logProgress("${lines.length - 1} words recognized");

    for (int linesIndex = 1; linesIndex < lines.length; linesIndex++) {
      final List<String> wordsOfLine =
          csvParser.getWordsOfLine(lines[linesIndex]);
      final String key = wordsOfLine.first;
      final List<String> words =
          wordsOfLine.sublist(startIndex, wordsOfLine.length);
      if (words.length > supportedLanguages.length) {
        FlappyLogger.logError(
            "The line number ${linesIndex + 1} seems to be not well formatted (${words.length} words for ${supportedLanguages.length} columns)");
        return;
      }
      final String defaultWord = words[0];

      if (defaultWord.isEmpty) {
        FlappyLogger.logError("$key has no translation for default language");
        return;
      }

      if (_isKeyAReservedWord(key)) {
        FlappyLogger.logError(
            "$key is a reserved keyword in Dart and cannot be used as key (line ${linesIndex + 1})\nAll reserved words in Dart are : $RESERVED_WORDS");
        return;
      }

      List<String> groupedKeysForKey = _getGroupedKeysForKey(groupedKey, key);
      for (String groupedKey in groupedKeysForKey) {
        groupedKeysValues[groupedKey].add(key.substring(groupedKey.length));
      }

      fields += _addField(key, defaultWord,
          dependsOnContext: dependOnContext, quoteString: quoteString);

      maps[0][key] = defaultWord;
      for (int wordIndex = 1; wordIndex < words.length; wordIndex++) {
        maps[wordIndex][key] =
            words[wordIndex].isEmpty ? defaultWord : words[wordIndex];
      }
    }

    template = template.replaceAll(FIELDS_AREA_TEMPLATE_KEY, fields);

    template = template.replaceAll(GROUPED_KEYS_AREA_TEMPLATE_KEY,
        _generateGroupedKeysArea(groupedKeysValues));

    template = template.replaceAll(
      VALUES_AREA_TEMPLATE_KEY,
      _generateStringValuesFromList(
        maps,
        supportedLanguages,
        quoteString: quoteString,
        replaceNoBreakSpaces: replaceNoBreakSpaces,
      ),
    );

    _writeInFile(template, outputDir, fileName);

    FlappyLogger.logProgress("End of work !");
  }

  void _writeInFile(String contents, String outputDir, String fileName) {
    // format the contents according to dart defaults
    contents = DartFormatter().format(contents);

    final File generatedFile = File(outputDir == null || outputDir.isEmpty
        ? 'i18n.dart'
        : '$outputDir/$fileName.dart');
    if (!generatedFile.existsSync()) {
      generatedFile.createSync(recursive: true);
    }
    generatedFile.writeAsStringSync(contents, mode: FileMode.write);
  }

  String _generateStringValuesFromList(
      List<Map<String, String>> maps, List<String> supportedLanguages,
      {String quoteString = '"', bool replaceNoBreakSpaces = false}) {
    final Map<String, Map<String, String>> allValuesMap = Map();
    final List<String> mapsNames = [];
    String result = "";

    for (int mapIndex = 0; mapIndex < maps.length; mapIndex++) {
      final String lang = supportedLanguages[mapIndex];
      final Map<String, String> map = maps[mapIndex];
      final String mapName = "_${lang.replaceAll("_", "")}Values";
      mapsNames.add(mapName);

      result += """
      static final Map<String, String> $mapName = <String, String>{
      """;

      map.forEach((key, value) {
        String formattedString = _formatString(value);
        if (quoteString == '\'') {
          formattedString = formattedString.replaceAll('\'', '\\\'');
          // incase the string already had \' then it will become \\\\\', replace this with \\\'
          formattedString = formattedString.replaceAll('\\\\\'', '\\\'');
        }
        if (replaceNoBreakSpaces) {
          formattedString = _replaceNoBreakSpaces(formattedString);
        }
        result += """
        $quoteString$key$quoteString: $quoteString$formattedString$quoteString,
        """;
      });

      result += "};\n\n";

      allValuesMap[lang] = map;
    }

    result += """
    static final Map<String, Map<String, String>> _allValues = 
    <String, Map<String, String>>{
    """;

    supportedLanguages.asMap().forEach((index, lang) {
      result += """
        $quoteString$lang$quoteString: ${mapsNames[index]},
      """;
    });

    result += "};";

    return result;
  }

  String _formatString(String text) {
    text = text.replaceAll('"', '\\"');
    text = text.replaceAll('\$', '\\\$');

    return text;
  }

  String _replaceNoBreakSpaces(String text) {
    // sometimes there can be the strange '194 160' space, ie `no break space`. replace this with a normal space.
    text = text.replaceAll('\u00A0', ' ');
    text = text.replaceAll(' ', ' ');

    return text;
  }

  List<Map<String, String>> _generateValuesMaps(
      List<String> supportedLanguages) {
    final List<Map<String, String>> maps = [];
    supportedLanguages.forEach((supportedLanguage) => maps.add(Map()));
    return maps;
  }

  Map<String, Set<String>> _generateGroupedKeysMap(
      Iterable<String> groupedKeys) {
    Map<String, Set<String>> map = {};

    for (String key in groupedKeys) {
      map[key] = Set<String>();
    }

    return map;
  }

  List<String> _getGroupedKeysForKey(Iterable<String> groupedKeys, String key) {
    List<String> relatedGroupedKeys = [];

    for (String groupedKey in groupedKeys) {
      if (key.startsWith(groupedKey)) {
        relatedGroupedKeys.add(groupedKey);
      }
    }

    return relatedGroupedKeys;
  }

  String _generateGroupedKeysArea(Map<String, Set<String>> groupedKeysValues) {
    StringBuffer buffer = StringBuffer();

    for (String key in groupedKeysValues.keys) {
      buffer.writeln('String $key(String key) {\nswitch (key) {');

      for (String value in groupedKeysValues[key]) {
        buffer.writeln('case \'$value\': return _getText(\'$key$value\');');
      }

      buffer.writeln(
          '}\nthrow Exception(\'No translation available for key $key\');\n}');
    }

    return buffer.toString();
  }

  String _addField(String key, String defaultWord,
      {bool dependsOnContext = false, String quoteString = '"'}) {
    final RegExp regex = new RegExp(PARAMETERS_REGEX);
    final bool hasParameters = regex.hasMatch(defaultWord);
    if (hasParameters) {
      String parameters = "";
      final List<RegExpMatch> matches = regex.allMatches(defaultWord).toList();
      for (RegExpMatch match in matches) {
        final String parameterType = match.group(2) == "d" ? "int" : "String";
        parameters +=
            "@required $parameterType ${getParameterNameFromPlaceholder(match.group(0))}, ";
      }

      String result = (!dependsOnContext ? "static " : "") +
          """String $key({$parameters}) {
      String text = _getText($quoteString$key$quoteString);
      """;

      for (RegExpMatch match in matches) {
        final String placeholderName = _formatString(match.group(1));
        String varName = getParameterNameFromPlaceholder(match.group(0));
        result += """
        if ($varName != null) {
          text = text.replaceAll("$placeholderName", ${varName += match.group(2) == "d" ? ".toString()" : ""});
        }
        """;
      }

      return result +
          """
      return text;
      
      }
      """;
    }
    return (!dependsOnContext ? "static " : "") +
        """String get $key => _getText($quoteString$key$quoteString);\n\n""";
  }

  String getParameterNameFromPlaceholder(String placeholder) {
    String givenName = placeholder.substring(1, placeholder.length - 2);
    if (int.tryParse(givenName[0]) != null) {
      givenName = "var$givenName";
    }
    return givenName;
  }

  String _replaceSupportedLanguages(
      String template, List<String> supportedLanguages) {
    final StringBuffer languageLocals = StringBuffer();

    for (String lang in supportedLanguages) {
      languageLocals.write(createLocalConstructorFromLanguage(lang) + ',');
    }

    final String supportedLocals = """
    static final Set<Locale> supportedLocals = <Locale>{ $languageLocals };
    """
        .trim();

    return template.replaceAll(
      SUPPORTED_LANGUAGES_AREA_TEMPLATE_KEY,
      """
      $supportedLocals
      
      @override
      bool isSupported(Locale locale) => supportedLocals.contains(locale);
      """
          .trim(),
    );
  }

  String createLocalConstructorFromLanguage(String language) {
    final List<String> parts = language.split('_');
    return (parts.length == 1)
        ? """Locale('${parts[0]}')"""
        : """Locale('${parts[0]}', '${parts[1]}')""";
  }

  bool _isKeyAReservedWord(String key) {
    return RESERVED_WORDS.contains(key);
  }
}
