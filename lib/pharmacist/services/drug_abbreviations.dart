/// Chemical-formula/abbreviation shorthand doctors write instead of the
/// full generic name (e.g. "Rx FeSO4 tab #30" for Ferrous Sulfate).
///
/// These score too poorly against the real name under plain Levenshtein
/// similarity to ever cross [PrescriptionParserService]'s fuzzy-match
/// threshold ("feso4" vs. "ferrous sulfate" isn't a few-typo edit apart,
/// it's a genuinely different string) — so they need to be resolved as a
/// direct lookup before that similarity pass runs, not by loosening the
/// threshold.
///
/// This applies regardless of which dictionary is in use. The offline
/// fallback list used to carry "feso4" as its own separate entry, which
/// only fixed the case where that fallback list was actually what got
/// searched. In production the dictionary is
/// MedicineDictionaryService's live, backend-supplied catalog instead —
/// which has no such alias unless someone adds "FeSO4" as a literal
/// product/generic name — so the exact same scan still failed there.
/// Resolving here fixes it for whichever dictionary is actually active.
class DrugAbbreviations {
  DrugAbbreviations._();

  static const Map<String, String> _knownAbbreviations = {
    'feso4': 'ferrous sulfate',
    'fe so4': 'ferrous sulfate',
    // Raw Groq OCR output for the official abbreviation "FeSO4" — the
    // "4" gets dropped/merged into "ov" by the recognizer (the same
    // digit-misread problem _digitLikeChars handles elsewhere, just not
    // a substitution covered there). Not a different drug or brand —
    // still FeSO4, so it resolves to the same target as "feso4" above.
    'fesov': 'ferrous sulfate',
  };

  /// Looks up [window] (a lowercased 1-3 word leading window of an OCR
  /// line, already trimmed) against the known-abbreviation map, and
  /// returns the target generic name ONLY if it actually exists in
  /// [drugDictionary] (case-insensitive) — never invents a resolution
  /// for stock this pharmacy doesn't actually carry. Returns null if
  /// [window] isn't a known abbreviation, or its target isn't in the
  /// dictionary.
  static String? resolve(String window, List<String> drugDictionary) {
    final target = _knownAbbreviations[window];
    if (target == null) return null;
    final inDictionary = drugDictionary.any((d) => d.toLowerCase() == target);
    return inDictionary ? target : null;
  }
}
