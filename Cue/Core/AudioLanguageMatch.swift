import Foundation

/// Is a track (audio or subtitles) in a language? Files tag it as "eng",
/// "en", "ger" or nothing at all, with the language in the track's title
/// instead: match on the tag when there is one, else on the title's words,
/// knowing the spellings each language appears under.
enum AudioLanguageMatch {

    /// ISO 639-1 code → every spelling that means the same language: the
    /// 639-2/T and 639-2/B three-letter forms (which disagree for exactly the
    /// languages people configure most — ger/deu, fre/fra), the English name,
    /// and the endonym releases label tracks with.
    private static let aliases: [String: Set<String>] = [
        "en": ["en", "eng", "english"],
        "es": ["es", "spa", "esl", "spanish", "espanol", "castellano", "latino"],
        "fr": ["fr", "fra", "fre", "french", "francais"],
        "de": ["de", "deu", "ger", "german", "deutsch"],
        "it": ["it", "ita", "italian", "italiano"],
        "pt": ["pt", "por", "portuguese", "portugues", "brazilian"],
        "ja": ["ja", "jpn", "jap", "japanese"],
        "ko": ["ko", "kor", "korean"],
        "zh": ["zh", "zho", "chi", "chinese", "mandarin", "cantonese"],
        "hi": ["hi", "hin", "hindi"],
        "ru": ["ru", "rus", "russian"],
        "ar": ["ar", "ara", "arabic"],
        // Not an allow-list: any language NOT named here still matches through
        // `normalizedCode` + the localized-name fallback below. This (and the
        // table above) only add the endonyms / 639-2 forms Foundation does not
        // know for a few languages people configure most.
        "vi": ["vi", "vie", "vietnamese", "tieng viet"],
        "th": ["th", "tha", "thai"],
        "tr": ["tr", "tur", "turkish", "turkce"],
        "nl": ["nl", "nld", "dut", "dutch", "nederlands"],
        "pl": ["pl", "pol", "polish", "polski"],
        "id": ["id", "ind", "indonesian", "bahasa"],
        "uk": ["uk", "ukr", "ukrainian"],
        "el": ["el", "ell", "gre", "greek"],
        "he": ["he", "iw", "heb", "hebrew"],
        "sv": ["sv", "swe", "swedish", "svenska"],
        "no": ["no", "nor", "norwegian", "norsk"],
        "da": ["da", "dan", "danish", "dansk"],
        "fi": ["fi", "fin", "finnish", "suomi"],
        "cs": ["cs", "ces", "cze", "czech"],
        "hu": ["hu", "hun", "hungarian", "magyar"],
        "ro": ["ro", "ron", "rum", "romanian"],
        "fa": ["fa", "fas", "per", "persian", "farsi"],
        "ms": ["ms", "msa", "may", "malay"],
        "ta": ["ta", "tam", "tamil"],
        "te": ["te", "tel", "telugu"],
        "bn": ["bn", "ben", "bengali"],
        "ur": ["ur", "urd", "urdu"],
        "tl": ["tl", "fil", "tagalog", "filipino"],
    ]

    /// Every alias of the preferred language. Unknown languages still get the
    /// code itself plus its localized name, so nothing is excluded by omission.
    static func aliases(for preferred: String) -> Set<String> {
        let base = normalizedCode(preferred)
        if let known = aliases[base] {
            var out = known
            // Include the current locale's name for the language too: a track
            // labelled "Vietnamese" must satisfy a preference stored as "vi".
            if let full = Locale.current.localizedString(forLanguageCode: base)?.lowercased() {
                out.insert(full)
            }
            return out
        }
        // Not a language we have a table for: match its own spellings only.
        var out: Set<String> = [base]
        if let full = Locale.current.localizedString(forLanguageCode: base)?.lowercased() {
            out.insert(full)
        }
        if let full = Locale.current.localizedString(forLanguageCode: preferred)?.lowercased() {
            out.insert(full)
        }
        return out
    }

    /// Reduce any language tag to its canonical two-letter ISO 639-1 base:
    /// "en-US" → "en", "eng" → "en", "vie" → "vi", "ger" → "de".
    ///
    /// Foundation's own identifier parser does the 639-2/B and 639-2/T mapping,
    /// so this works for EVERY language rather than only the alias table above.
    /// Unrecognized tags are returned lowercased and otherwise untouched.
    static func normalizedCode(_ code: String) -> String {
        let bare = code.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? code.lowercased()
        guard !bare.isEmpty, bare != "und" else { return bare }
        if bare.count == 2 { return bare }
        for (short, forms) in aliases where forms.contains(bare) { return short }
        if let canonical = Locale(identifier: bare).language.languageCode?.identifier,
           canonical.count == 2, canonical != bare {
            return canonical
        }
        return bare
    }

    /// A track's language as a code: its tag, else a language its title
    /// names ("English", "Deutsch"); nil when neither says.
    static func language(code: String?, label: String?) -> String? {
        if let code, !code.isEmpty, code.lowercased() != "und" { return normalizedCode(code) }
        guard let label, !label.isEmpty else { return nil }
        let words = Set(
            label.folding(options: [.diacriticInsensitive, .caseInsensitive],
                          locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count > 3 }   // names, not "en" or "de" inside a title
        )
        return aliases.first { !$0.value.isDisjoint(with: words) }?.key
    }

    /// A human-readable name for a language tag, preserving the raw tag as the
    /// fallback when Foundation doesn't recognize it. Returns nil only for an
    /// empty tag, so callers can still choose their own "Unknown" wording.
    static func displayName(for code: String?) -> String? {
        guard let code, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let name = Locale.current.localizedString(forLanguageCode: normalizedCode(code)),
           !name.isEmpty {
            return name
        }
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty {
            return name
        }
        return code
    }

    /// Does this track carry the preferred language?
    ///
    /// - Parameters:
    ///   - code: the container's language tag, if the engine exposes one.
    ///   - label: the track's display name, the
    ///     fallback whenever a file tags no language.
    ///   - preferred: the configured (or remembered) language.
    static func matches(code: String?, label: String?, preferred: String) -> Bool {
        let preferred = preferred.trimmingCharacters(in: .whitespaces)
        guard !preferred.isEmpty else { return false }
        let wanted = aliases(for: preferred)

        // A real language tag is definitive — believe it, either way. Without
        // this, an "eng"-tagged track sitting in a file whose title says
        // "Latino" could match a Spanish preference off the label.
        if let code, !code.isEmpty, code.lowercased() != "und" {
            return wanted.contains(normalizedCode(code))
        }

        guard let label, !label.isEmpty else { return false }
        // Whole words only: "en" is inside "French" and a contains-check on the
        // bare code is how the French track once won an English preference.
        let words = Set(
            label.folding(options: [.diacriticInsensitive, .caseInsensitive],
                          locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        return !words.isDisjoint(with: wanted)
    }

    /// A commentary, described-video or otherwise secondary track, spotted from
    /// its label. The FFmpeg paths also have disposition flags, which are more
    /// reliable; this catches the files that set no flags and say it in words.
    static func isSecondary(label: String?) -> Bool {
        guard let label = label?.lowercased() else { return false }
        for marker in ["commentary", "description", "descriptive", "narration",
                       "sdh", "visual impaired", "audio description"]
        where label.contains(marker) {
            return true
        }
        return false
    }
}
