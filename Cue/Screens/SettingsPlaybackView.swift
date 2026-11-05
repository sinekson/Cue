import SwiftUI

/// Settings → Playback: the language titles play in. Everything else is
/// chosen in the player (Audio, Subtitles and its Style).
struct PlaybackSettingsDetail: View {
    @EnvironmentObject private var store: PlayerSettingsStore

    var body: some View {
        let settings = store.settings
        SettingsPage(title: SettingsCategory.playback.title) {
            SettingsSection {
                SettingsOptionsRow(
                    title: "Language",
                    pageDescription: "Choose the language for audio and subtitles. "
                        + "A track you pick in the player is kept for that title.",
                    options: [SettingsOption(id: "", label: "Device Language")]
                        + PlayerSettings.languages(including: settings.language).map { SettingsOption(id: $0.code, label: $0.name) },
                    selection: settings.language
                ) { store.settings.language = $0 }
                SettingsOptionsRow(
                    title: "Original Audio",
                    pageDescription: "Play a title in the language it was made in, when the link has it. "
                        + "Anime: Japanese animation only.",
                    options: [SettingsOption(id: PlayerSettings.OriginalAudio.off.rawValue, label: "Off"),
                              SettingsOption(id: PlayerSettings.OriginalAudio.anime.rawValue, label: "Anime"),
                              SettingsOption(id: PlayerSettings.OriginalAudio.all.rawValue, label: "All Titles")],
                    selection: settings.originalAudio.rawValue
                ) { store.settings.originalAudio = PlayerSettings.OriginalAudio(rawValue: $0) ?? .off }
                SettingsOptionsRow(
                    title: "Subtitles",
                    pageDescription: "Auto shows subtitles in your language when the audio is in another, "
                        + "and only forced ones (signs, foreign lines) when it isn't.",
                    options: [SettingsOption(id: PlayerSettings.Subtitles.auto.rawValue, label: "Auto"),
                              SettingsOption(id: PlayerSettings.Subtitles.always.rawValue, label: "Always"),
                              SettingsOption(id: PlayerSettings.Subtitles.off.rawValue, label: "Off")],
                    selection: settings.subtitles.rawValue
                ) { store.settings.subtitles = PlayerSettings.Subtitles(rawValue: $0) ?? .auto }
            }
        }
    }
}
