import Foundation

/// Settings → Playback: the language titles play in. A track picked by
/// hand for a title (`PlaybackMemory`) comes before these.
/// Per profile, synced to Nuvio in `nuvio_tvos_preferences`.
struct PlayerSettings: Codable, Equatable {
    /// Audio and subtitles alike; "" = the device's language.
    var language: String = ""
    /// The title's own language (TMDB's) over `language`, where the link has it.
    var originalAudio: OriginalAudio = .off
    var subtitles: Subtitles = .auto

    enum OriginalAudio: String, Codable, CaseIterable {
        /// Anime: Japanese and in TMDB's Animation genre.
        case off, anime, all
    }

    enum Subtitles: String, Codable, CaseIterable {
        /// Auto: full subtitles when the audio isn't `language`; when it is,
        /// only forced ones (signs, foreign lines).
        case auto, always, off
    }

    static let `default` = PlayerSettings()

    init() {}

    /// The language as a code, the device's for "".
    var languageCode: String {
        if !language.isEmpty { return language }
        return Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
    }

    /// The title's original language when Original Audio asks for it and
    /// it isn't the language anyway.
    func originalAudio(original: String?, animation: Bool) -> String? {
        guard let original, !original.isEmpty,
              AudioLanguageMatch.normalizedCode(original) != AudioLanguageMatch.normalizedCode(languageCode)
        else { return nil }
        switch originalAudio {
        case .off: return nil
        case .anime: return AudioLanguageMatch.normalizedCode(original) == "ja" && animation ? original : nil
        case .all: return original
        }
    }

    private enum CodingKeys: String, CodingKey { case language, originalAudio, subtitles }
    /// Before one language: audio's became it, subtitles on became Always.
    private enum OldKeys: String, CodingKey { case preferredAudioLanguage, subtitlesOnByDefault }

    /// A missing key takes its default, so an older save or an account's
    /// copy still loads; keys this version no longer has are skipped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let old = try decoder.container(keyedBy: OldKeys.self)
        let d = PlayerSettings.default
        language = (try? c.decode(String.self, forKey: .language))
            ?? (try? old.decode(String.self, forKey: .preferredAudioLanguage)) ?? d.language
        originalAudio = (try? c.decode(OriginalAudio.self, forKey: .originalAudio)) ?? d.originalAudio
        subtitles = (try? c.decode(Subtitles.self, forKey: .subtitles))
            ?? ((try? old.decode(Bool.self, forKey: .subtitlesOnByDefault)) == true ? .always : d.subtitles)
    }

    /// The languages Settings offers: the common ones by name, and the one
    /// chosen, whatever it is.
    static func languages(including current: String) -> [(code: String, name: String)] {
        let codes = commonLanguageCodes.union(current.isEmpty ? [] : [current])
        return codes.compactMap { code in
            Locale.current.localizedString(forLanguageCode: code).map { (code, $0) }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let commonLanguageCodes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl",
        "sv", "da", "no", "fi", "tr", "cs", "el", "hu", "ro",
        "ar", "he", "hi", "bn", "ta", "te", "ur", "fa",
        "ja", "ko", "zh", "th", "vi", "id", "ms", "tl",
    ]
}

@MainActor
final class PlayerSettingsStore: ObservableObject {
    @Published var settings: PlayerSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            if !applyingRemote { onLocalChange?() }
        }
    }

    /// Fired on a change made here (not a remote pull), so the sync manager
    /// can push it up.
    var onLocalChange: (() -> Void)?
    private var applyingRemote = false

    private static let key = "cue.player.settings.v1"

    private(set) var profileID: Int

    init() {
        profileID = ProfileScopedDefaults.activeProfileID
        settings = Self.load(profile: profileID)
    }

    private static func load(profile: Int) -> PlayerSettings {
        guard let data = ProfileScopedDefaults.data(key, profile),
              let decoded = try? JSONDecoder().decode(PlayerSettings.self, from: data) else { return .default }
        return decoded
    }

    /// Point the store at a profile. Applied as "remote" so the swap doesn't
    /// push settings that didn't change.
    func setProfile(_ id: Int) {
        guard id != profileID else { return }
        profileID = id
        applyingRemote = true
        settings = Self.load(profile: id)
        applyingRemote = false
    }

    /// Forget a deleted profile's settings so a recycled id starts fresh.
    func forgetProfile(_ id: Int) {
        ProfileScopedDefaults.forget([Self.key], profile: id)
        if id == profileID {
            applyingRemote = true
            settings = Self.load(profile: id)
            applyingRemote = false
        }
    }

    /// Settings pulled from the account, without echoing them back up.
    func applyRemote(_ new: PlayerSettings) {
        guard new != settings else { return }
        applyingRemote = true
        settings = new
        applyingRemote = false
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(
            data, forKey: ProfileScopedDefaults.key(Self.key, profileID))
    }
}
