import SwiftUI

/// Playback's sub-pages.
enum PlaybackSection: String, CaseIterable, Identifiable, Hashable {
    case player, audioSubtitles, sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "Player"
        case .audioSubtitles: return "Audio & Subtitles"
        case .sources: return "Sources"
        }
    }

    var subtitle: String {
        switch self {
        case .player: return "Engine, Up Next and auto-play, seeking, on-screen display"
        case .audioSubtitles: return "Languages, surround sound, how captions look"
        case .sources: return "Which links show, auto-playing a source, badges"
        }
    }

    var icon: String {
        switch self {
        case .player: return "play.rectangle.fill"
        case .audioSubtitles: return "captions.bubble.fill"
        case .sources: return "list.bullet.rectangle.fill"
        }
    }
}

/// Settings → Playback: a page listing its sub-pages (`PlaybackSection`),
/// and each sub-page. Every row is wired to `PlayerSettingsStore` and
/// actually changes player behaviour.
struct PlaybackSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var store: PlayerSettingsStore
    @EnvironmentObject private var layout: HomeCatalogSettingsStore
    /// nil: the Playback page (its sub-pages listed); else that sub-page.
    var section: PlaybackSection? = nil
    @State private var showAudioLanguages = false
    @State private var showSubtitleLanguages = false

    private var s: Binding<PlayerSettings> {
        Binding(get: { store.settings }, set: { store.settings = $0 })
    }

    var body: some View {
        settingsScaffold
            .fullScreenCover(isPresented: $showAudioLanguages) { audioLanguagesSheet }
            .fullScreenCover(isPresented: $showSubtitleLanguages) { subtitleLanguagesSheet }
    }

    /// The pane itself. Kept apart from `body` so the (large) card tree and the
    /// two sheet modifiers are type-checked separately — together they were too
    /// much for the checker, which failed on the first `.fullScreenCover`.
    @ViewBuilder
    private var settingsScaffold: some View {
        switch section {
        case nil:
            DetailScaffold(title: SettingsCategory.playback.title, subtitle: SettingsCategory.playback.subtitle) {
                SettingsGroupCard(title: "") {
                    ForEach(PlaybackSection.allCases) { section in
                        NavigationLink(value: section) {
                            SettingsActionRow(title: section.title, subtitle: section.subtitle,
                                              leadingIcon: section.icon)
                        }
                        .buttonStyle(PlainCardButtonStyle())
                    }
                }
            }
        case .player?:
            DetailScaffold(title: PlaybackSection.player.title, subtitle: PlaybackSection.player.subtitle) {
                playerGroup
                autoPlayGroup
                seekingGroup
                onScreenGroup
            }
        case .audioSubtitles?:
            DetailScaffold(title: PlaybackSection.audioSubtitles.title,
                           subtitle: PlaybackSection.audioSubtitles.subtitle) {
                audioGroup
                subtitlesGroup
            }
        case .sources?:
            DetailScaffold(title: PlaybackSection.sources.title, subtitle: PlaybackSection.sources.subtitle) {
                sourcesGroup
                SettingsGroupCard(title: "Source list") {
                    SettingsToggleCard(
                        title: "Full stream names",
                        subtitle: "On the source list, show every link's complete release name — wrapped across lines instead of cut off.",
                        isOn: $layout.fullStreamTitles
                    )
                }
                SettingsGroupCard(title: "Badges", subtitle: "Badge packs from Badger (nintle.github.io/Badger) shown on source rows") {
                    StreamBadgeSettings()
                }
            }
        }
    }

    @ViewBuilder
    private var autoPlayGroup: some View {
        SettingsGroupCard(title: "Auto-play", subtitle: "What happens when an episode finishes") {
            autoPlayControls
        }
    }

    @ViewBuilder
    private var seekingGroup: some View {
        SettingsGroupCard(title: "Seeking", subtitle: "How far a single skip jumps") {
            CueDropdown(
                title: "Skip amount",
                subtitle: "Each left/right press; rapid presses add up, holding accelerates",
                icon: "goforward",
                selection: String(store.settings.skipSeconds),
                options: PlayerSettings.skipValues.map { CueDropdownOption(String($0), "\($0) seconds") }
            ) { store.settings.skipSeconds = Int($0) ?? 10 }

            CueDropdown(
                title: "Scrubber jump",
                subtitle: "Left/right press while scrubbing with the trackpad",
                icon: "forward.frame.fill",
                selection: String(store.settings.scrubJumpSeconds),
                options: PlayerSettings.scrubJumpValues.map {
                    CueDropdownOption(String($0), $0 < 60 ? "\($0) seconds" : "\($0 / 60) minute\($0 >= 120 ? "s" : "")")
                }
            ) { store.settings.scrubJumpSeconds = Int($0) ?? 60 }

            PlaybackToggleRow(
                icon: "forward.frame.fill",
                title: "Skip Intro button",
                subtitle: "Show a Skip Intro pill while inside an intro/recap chapter (⏯ skips it)",
                isOn: s.skipIntroEnabled
            )

            PlaybackToggleRow(
                icon: "forward.fill",
                title: "Auto-skip intros",
                subtitle: "Jump past intro and recap chapters automatically, no button press. Needs chapter markers in the file.",
                isOn: s.autoSkipSegments
            )

            PlaybackToggleRow(
                icon: "sparkles.tv",
                title: "AniSkip for anime",
                subtitle: "Fetch intro/outro skip times from the public AniSkip database for anime episodes that carry no chapter markers, so Skip Intro and Up Next work on anime web releases. No account or key needed.",
                isOn: s.animeSkipEnabled
            )
        }
    }

    @ViewBuilder
    private var sourcesGroup: some View {
        SettingsGroupCard(title: "Sources", subtitle: "Which links the source lists show") {
            PlaybackToggleRow(
                icon: "line.3.horizontal.decrease.circle.fill",
                title: "Link filters",
                subtitle: "Smart-rank links: each addon grouped by resolution — scored by cached status, release quality (REMUX > Blu-ray > WEB-DL), codec, HDR/DV, audio, seeders and bitrate. Off = show links exactly as each addon returns them (cached still first), up to \(PlayerSettings.unfilteredPerAddonCap) per addon",
                isOn: s.sourceFiltersEnabled
            )

            if store.settings.sourceFiltersEnabled {
                CueDropdown(
                    title: "Links per resolution",
                    subtitle: "Best-scored links kept in each of 2160p / 1080p / 720p / 480p per addon",
                    icon: "square.stack.3d.up.fill",
                    selection: String(store.settings.sourcesPerSizeTier),
                    options: PlayerSettings.sourcesPerTierValues.filter { $0 > 0 }.map {
                        CueDropdownOption(String($0), "\($0) links")
                    }
                ) { store.settings.sourcesPerSizeTier = Int($0) ?? 6 }
            }

            CueDropdown(
                title: "Source search patience",
                subtitle: "How long each addon gets to answer a stream search. Raise it for aggregators that query Usenet indexers behind the scenes (AIOStreams with NZBgeek) — their full results can outlast the standard deadline. Fast addons still show up the moment they answer.",
                icon: "clock.arrow.circlepath",
                selection: String(store.settings.sourceSearchTimeoutSeconds),
                options: [45, 60, 90, 120].map {
                    CueDropdownOption(String($0), "\($0) seconds")
                }
            ) { store.settings.sourceSearchTimeoutSeconds = Int($0) ?? 45 }

            CueDropdown(
                title: "Minimum resolution",
                subtitle: "Hide links below this quality (links with no resolution tag are kept)",
                icon: "arrow.up.right.video.fill",
                selection: store.settings.streamMinResolution,
                options: [CueDropdownOption("", "No minimum")]
                    + ["2160p", "1080p", "720p", "480p"].map { CueDropdownOption($0, $0) }
            ) { store.settings.streamMinResolution = $0 }

            PlaybackToggleRow(
                icon: "cpu.fill",
                title: "Hide AV1 links",
                subtitle: "AV1 has no hardware decode on the Apple TV — those links stutter",
                isOn: s.streamExcludeAV1
            )

            PlaybackToggleRow(
                icon: "sparkles",
                title: "HDR only",
                subtitle: "Only show HDR10 / HLG / Dolby Vision links",
                isOn: s.streamHDROnly
            )

            PlaybackToggleRow(
                icon: "sparkles.tv.fill",
                title: "Dolby Vision only",
                subtitle: "Only show Dolby Vision links",
                isOn: s.streamDolbyVisionOnly
            )

            PlaybackToggleRow(
                icon: "bolt.fill",
                title: "Cached only",
                subtitle: "Only show debrid-cached links (instant play, no download wait)",
                isOn: s.streamCachedOnly
            )
        }
    }

    @ViewBuilder
    private var playerGroup: some View {
        SettingsGroupCard(title: "Player", subtitle: "Which engine opens streams") {
            CueDropdown(
                title: "Playback engine",
                subtitle: store.settings.playerEngine.footnote,
                icon: "play.rectangle.on.rectangle.fill",
                selection: store.settings.playerEngine.rawValue,
                options: PlayerEngine.allCases.map { CueDropdownOption($0.rawValue, $0.label) }
            ) { store.settings.playerEngine = PlayerEngine(rawValue: $0) ?? .auto }

            CueDropdown(
                title: "Playback mode",
                subtitle: "Automatic picks the best supported path. Maximum Fidelity never downgrades (native Dolby Vision, Profile 7 conversion always on, Atmos renderer when the route supports it) — heaviest on older boxes. Compatibility takes the most forgiving path for streams that misbehave.",
                icon: "dial.high.fill",
                selection: store.settings.playbackMode.rawValue,
                options: PlaybackMode.allCases.map { CueDropdownOption($0.rawValue, $0.label) }
            ) { store.settings.playbackMode = PlaybackMode(rawValue: $0) ?? .automatic }

            PlaybackToggleRow(
                icon: "sun.max.fill",
                title: "Brighten Profile 7 Dolby Vision",
                subtitle: "Convert Dolby Vision Profile 7 to 8.1 so the enhancement layer's brightness survives, instead of playing the dark HDR10 base layer. Costs CPU on older Apple TVs — turn off if a Profile 7 title stutters.",
                isOn: s.convertProfile7ForBrightness
            )

            PlaybackToggleRow(
                icon: "speedometer",
                title: "Match frame rate (24p)",
                subtitle: "Switch the TV to the film's true rate (e.g. 24Hz), which removes 3:2 pulldown so 24p film plays with no repeated frames. OFF by default: this rate change is a heavier HDMI renegotiation than a range-only switch, and some TVs mis-handshake it into a grey screen (recovering flashes through several more mode changes). Turn ON only if your TV handles 24p switches cleanly.",
                isOn: s.matchFrameRate
            )

            PlaybackToggleRow(
                icon: "waveform.badge.plus",
                title: "Dolby Atmos passthrough (experimental)",
                subtitle: "ON by default. For an E-AC-3 track the container tags as Dolby Atmos, re-mux the audio into a local HLS stream and play it with AVPlayer, so an HDMI receiver gets true Dolby Atmos instead of PCM. Engages only when the track declares Atmos and the route is HDMI; falls back automatically otherwise.",
                isOn: s.atmosPassthrough
            )

            PlaybackToggleRow(
                icon: "internaldrive.fill",
                title: "Hybrid disk cache",
                subtitle: "Download the film to the Apple TV's storage at full speed while playing, so seeking anywhere already-downloaded is instant — like Infuse. A film too big for the free space keeps a sliding window instead, filling in around wherever you have been. Direct-file streams only (HLS plays normally); the cache is deleted when playback ends.",
                isOn: s.hybridDiskCacheEnabled
            )

            CueDropdown(
                title: "Video scaling",
                subtitle: "Default zoom for the video. Cycle it live in the player with the aspect button.",
                icon: "aspectratio.fill",
                selection: store.settings.aspectModeRaw,
                options: AspectMode.allCases.map { CueDropdownOption($0.rawValue, $0.label) }
            ) { store.settings.aspectModeRaw = $0 }
        }
    }

    @ViewBuilder
    private var onScreenGroup: some View {
        SettingsGroupCard(title: "On-screen display", subtitle: "Player overlays and status") {
            PlaybackToggleRow(
                icon: "photo.fill",
                title: "Loading backdrop",
                subtitle: "Show the full-screen loading screen (artwork + spinner) while a stream opens",
                isOn: s.loadingOverlayEnabled
            )
            if store.settings.loadingOverlayEnabled {
                PlaybackToggleRow(
                    icon: "text.append",
                    title: "Loading status",
                    subtitle: "Show the “Loading / Caching %” text and cache bar on the loading screen",
                    isOn: s.showPlayerLoadingStatus
                )
            }
        }
    }

    @ViewBuilder
    private var audioGroup: some View {
        SettingsGroupCard(title: "Audio", subtitle: "Track selection and output") {
            CueDropdown(
                title: "Preferred language",
                subtitle: "Automatically pick a matching audio track when the stream has one",
                icon: "waveform",
                selection: store.settings.preferredAudioLanguage,
                options: PlayerSettings.audioLanguageOptions(
                    showAll: store.settings.allAudioLanguages,
                    enabled: Set(store.settings.enabledAudioLanguages),
                    current: store.settings.preferredAudioLanguage
                ).map { CueDropdownOption($0.0, $0.1) }
            ) { store.settings.preferredAudioLanguage = $0 }

            Button { showAudioLanguages = true } label: {
                SettingsActionRow(
                    title: "Audio languages",
                    subtitle: "Choose which languages the picker lists",
                    value: audioLanguagesSummary,
                    leadingIcon: "globe"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            CueDropdown(
                title: "Surround & Dolby Atmos",
                subtitle: "Auto uses the enhanced renderer (Atmos/spatial + lighter TrueHD/DTS-HD decode) only when your TV or receiver reports spatial-audio support. Takes effect on next playback.",
                icon: "hifispeaker.2.fill",
                selection: store.settings.audioOutputMode.rawValue,
                options: AudioOutputMode.allCases.map { CueDropdownOption($0.rawValue, $0.label) }
            ) { store.settings.audioOutputMode = AudioOutputMode(rawValue: $0) ?? .auto }
        }
    }

    @ViewBuilder
    private var subtitlesGroup: some View {
        SettingsGroupCard(title: "Subtitles", subtitle: "How captions look and when they turn on") {
            PlaybackToggleRow(
                icon: "captions.bubble.fill",
                title: "Subtitles on by default",
                subtitle: "Automatically enable subtitles when a stream loads, picking your preferred language when it's available",
                isOn: s.subtitlesOnByDefault
            )

            PlaybackToggleRow(
                icon: "textformat.alt",
                title: "Full styled subtitles (ASS/SSA)",
                subtitle: "Render fancy anime/fansub subtitles — custom fonts, positioning, karaoke — properly. Titles that carry ASS/SSA subtitles play in the VLC engine (which includes libass and reads embedded fonts). You lose that title's scrub-thumbnail preview while it plays. Off = the built-in renderer (readable text, but drops fonts/effects).",
                isOn: s.fullAssSubtitles
            )

            if store.settings.subtitlesOnByDefault {
                CueDropdown(
                    title: "Preferred language",
                    subtitle: "Chosen automatically when the stream has a matching subtitle; otherwise the first available is used",
                    icon: "globe",
                    selection: store.settings.preferredSubtitleLanguage,
                    options: PlayerSettings.subtitleLanguageOptions(
                        showAll: store.settings.allSubtitleLanguages,
                        enabled: Set(store.settings.enabledSubtitleLanguages),
                        current: store.settings.preferredSubtitleLanguage
                    ).map { CueDropdownOption($0.0, $0.1) }
                ) { store.settings.preferredSubtitleLanguage = $0 }

                CueDropdown(
                    title: "Secondary language",
                    subtitle: "Used when the preferred language isn't available",
                    icon: "globe.badge.chevron.backward",
                    selection: store.settings.subtitleSecondaryLanguage,
                    options: PlayerSettings.subtitleLanguageOptions(
                        showAll: store.settings.allSubtitleLanguages,
                        enabled: Set(store.settings.enabledSubtitleLanguages),
                        current: store.settings.subtitleSecondaryLanguage
                    ).map { CueDropdownOption($0.0, $0.1) }
                ) { store.settings.subtitleSecondaryLanguage = $0 }

                PlaybackToggleRow(
                    icon: "exclamationmark.bubble.fill",
                    title: "Prefer forced subtitles",
                    subtitle: "When a forced track (foreign dialogue only) exists in your language, choose it",
                    isOn: s.subtitlePreferForced
                )
            }

            Button { showSubtitleLanguages = true } label: {
                SettingsActionRow(
                    title: "Subtitle languages",
                    subtitle: "Turn on every language, or pick only the ones you want in the list",
                    value: subtitleLanguagesSummary,
                    leadingIcon: "globe"
                )
            }
            .buttonStyle(PlainCardButtonStyle())

            CueDropdown(
                title: "Text size",
                icon: "textformat.size",
                selection: String(store.settings.subtitleSize),
                options: PlayerSettings.subtitleSizeValues.map {
                    CueDropdownOption(String($0), sizeLabel($0))
                }
            ) { store.settings.subtitleSize = Int($0) ?? 36 }

            CueDropdown(
                title: "Font",
                subtitle: "Also adjustable live from the Subtitles panel during playback.",
                icon: "textformat",
                selection: store.settings.subtitleFontName,
                options: PlayerSettings.subtitleFontOptions.map { CueDropdownOption($0.0, $0.1) }
            ) { store.settings.subtitleFontName = $0 }

            CueDropdown(
                title: "Timing offset",
                subtitle: "Shift captions earlier (−) or later (+). Adjustable live from the Subtitles panel during playback.",
                icon: "timer",
                selection: String(store.settings.subtitleDelaySeconds),
                options: PlayerSettings.subtitleDelayValues.map {
                    CueDropdownOption(String($0), PlayerViewModel.formatDelay($0))
                }
            ) { store.settings.subtitleDelaySeconds = Double($0) ?? 0 }

            CueDropdown(
                title: "Text color",
                icon: "paintpalette.fill",
                selection: store.settings.subtitleTextColorHex,
                options: PlayerSettings.subtitleColorOptions.map { CueDropdownOption($0.0, $0.1) }
            ) { store.settings.subtitleTextColorHex = $0 }

            PlaybackToggleRow(
                icon: "bold",
                title: "Bold text",
                subtitle: "Heavier caption weight",
                isOn: s.subtitleBold
            )

            PlaybackToggleRow(
                icon: "a.square.fill",
                title: "Outline",
                subtitle: "Draw an outline around the text so it's readable on any background",
                isOn: s.subtitleOutlineEnabled
            )

            if store.settings.subtitleOutlineEnabled {
                CueDropdown(
                    title: "Outline color",
                    icon: "scribble",
                    selection: store.settings.subtitleOutlineColorHex,
                    options: PlayerSettings.subtitleColorOptions.map { CueDropdownOption($0.0, $0.1) }
                ) { store.settings.subtitleOutlineColorHex = $0 }

                CueDropdown(
                    title: "Outline thickness",
                    icon: "lineweight",
                    selection: String(store.settings.subtitleOutlineWidth),
                    options: PlayerSettings.subtitleOutlineWidthValues.map {
                        CueDropdownOption(String($0), $0 == 1 ? "Thin (1 pt)" : "\($0) pt")
                    }
                ) { store.settings.subtitleOutlineWidth = Int($0) ?? 2 }
            }

            PlaybackToggleRow(
                icon: "rectangle.fill.on.rectangle.fill",
                title: "Background plate",
                subtitle: "Panel behind captions for readability on bright scenes",
                isOn: s.subtitleBackground
            )

            if store.settings.subtitleBackground {
                CueDropdown(
                    title: "Background opacity",
                    icon: "circle.lefthalf.filled",
                    selection: String(store.settings.subtitleBackgroundOpacity),
                    options: PlayerSettings.subtitleBackgroundOpacityValues.map {
                        CueDropdownOption(String($0), "\($0)%")
                    }
                ) { store.settings.subtitleBackgroundOpacity = Int($0) ?? 45 }
            }

            CueDropdown(
                title: "Vertical position",
                subtitle: "Raise or lower the captions",
                icon: "arrow.up.and.down.text.horizontal",
                selection: String(store.settings.subtitleVerticalOffset),
                options: PlayerSettings.subtitleOffsetValues.map {
                    CueDropdownOption(String($0), $0 == 0 ? "Default" : ($0 > 0 ? "Higher +\($0)" : "Lower \($0)"))
                }
            ) { store.settings.subtitleVerticalOffset = Int($0) ?? 0 }
        }
    }

    @ViewBuilder
    private var autoPlayControls: some View {
        PlaybackToggleRow(
            icon: "forward.end.fill",
            title: "Auto-play next episode",
            subtitle: "Run a countdown on the Up Next card and start the next episode automatically. Off = the card still appears, but waits for you to press Play",
            isOn: s.autoPlayNextEpisode
        )

        // Shown regardless of auto-play — the Up Next card always appears.
        CueDropdown(
            title: "Show Up Next",
            subtitle: "When credits chapters exist the card appears as they start; otherwise this many seconds before the end",
            icon: "clock.fill",
            selection: String(store.settings.upNextLeadSeconds),
            options: PlayerSettings.upNextLeadValues.map {
                CueDropdownOption(String($0), $0 < 60 ? "\($0) seconds before end" : "\($0 / 60) min before end")
            }
        ) { store.settings.upNextLeadSeconds = Int($0) ?? 30 }

        if store.settings.autoPlayNextEpisode {
            PlaybackToggleRow(
                icon: "eye.fill",
                title: "Still watching?",
                subtitle: "Pause auto-play after several episodes to check you're still there",
                isOn: s.stillWatchingEnabled
            )

            if store.settings.stillWatchingEnabled {
                CueDropdown(
                    title: "Ask after",
                    icon: "repeat",
                    selection: String(store.settings.stillWatchingEpisodeThreshold),
                    options: (2...6).map { CueDropdownOption(String($0), "\($0) episodes") }
                ) { store.settings.stillWatchingEpisodeThreshold = Int($0) ?? 3 }
            }

            CueDropdown(
                title: "Auto-play countdown",
                icon: "timer",
                selection: String(store.settings.autoPlayTimeoutSeconds),
                options: PlayerSettings.timeoutValues.map { CueDropdownOption(String($0), timeoutLabel($0)) }
            ) { store.settings.autoPlayTimeoutSeconds = Int($0) ?? 3 }

            PlaybackToggleRow(
                icon: "square.stack.3d.up.fill",
                title: "Prefer same source group",
                subtitle: "Pick the next episode from the same release group when possible",
                isOn: s.preferBingeGroupForNextEpisode
            )

            if store.settings.preferBingeGroupForNextEpisode {
                PlaybackToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Reuse the same source",
                    subtitle: "Keep the next episode on the same addon as well as the same group, so it's as close to the current source as possible",
                    isOn: s.reuseBingeGroup
                )
            }
        }
    }

    private var audioLanguagesSheet: some View {
        LanguageSelectionDetail(
            title: "Audio languages",
            subtitle: "Turn on every language, or pick only the ones you want the audio picker to list.",
            allLabel: "All languages",
            allHint: "List every language the platform knows. Off = only the ones you turn on below.",
            all: s.allAudioLanguages,
            enabled: s.enabledAudioLanguages,
            options: Array(PlayerSettings.allAudioLanguageOptions.dropFirst())
        )
        .environmentObject(theme)
        .environmentObject(store)
        .onExitCommand { showAudioLanguages = false }
    }

    private var subtitleLanguagesSheet: some View {
        LanguageSelectionDetail(
            title: "Subtitle languages",
            subtitle: "Turn on every language, or pick only the ones you want the subtitle pickers to list.",
            allLabel: "All languages",
            allHint: "List every language the platform knows. Off = only the ones you turn on below.",
            all: s.allSubtitleLanguages,
            enabled: s.enabledSubtitleLanguages,
            options: Array(PlayerSettings.allSubtitleLanguageOptions.dropFirst())
        )
        .environmentObject(theme)
        .environmentObject(store)
        .onExitCommand { showSubtitleLanguages = false }
    }

    /// "All languages" or "N selected" for the drill-in rows.
    private var audioLanguagesSummary: String {
        store.settings.allAudioLanguages
            ? "All" : "\(store.settings.enabledAudioLanguages.count) selected"
    }
    private var subtitleLanguagesSummary: String {
        store.settings.allSubtitleLanguages
            ? "All" : "\(store.settings.enabledSubtitleLanguages.count) selected"
    }

    private func sizeLabel(_ size: Int) -> String {
        switch size {
        case ..<32: return "Small (\(size)pt)"
        case ..<40: return "Standard (\(size)pt)"
        case ..<50: return "Large (\(size)pt)"
        default: return "Huge (\(size)pt)"
        }
    }

    private func timeoutLabel(_ seconds: Int) -> String {
        if seconds == 0 { return "Instant" }
        if seconds == PlayerSettings.timeoutUnlimited { return "Wait for me" }
        return "\(seconds)s"
    }

}

// MARK: - Language selection

/// A drill-in language picker: an "All languages" master switch plus one
/// toggle per language. Keeps the audio/subtitle dropdowns short by default
/// while still making an uncommon language reachable — the alternative was a
/// ~180-entry dropdown or a language that simply could not be chosen.
struct LanguageSelectionDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let subtitle: String
    let allLabel: String
    let allHint: String
    @Binding var all: Bool
    @Binding var enabled: [String]
    /// Every selectable (code, name), WITHOUT the "no preference" first entry.
    let options: [(String, String)]

    var body: some View {
        DetailScaffold(title: title, subtitle: subtitle) {
            SettingsGroupCard(title: allLabel, subtitle: allHint) {
                PlaybackToggleRow(icon: "globe", title: allLabel,
                                  subtitle: allHint, isOn: allBinding)
            }
            if !all {
                SettingsGroupCard(
                    title: "Languages",
                    subtitle: "On: listed in the picker. Off: hidden. You can switch All languages back on at any time."
                ) {
                    ForEach(options, id: \.0) { code, name in
                        PlaybackToggleRow(icon: "character.bubble", title: name,
                                          subtitle: "", isOn: binding(for: code))
                    }
                }
            }
        }
    }

    /// Turning "All" off with nothing selected would leave an empty picker —
    /// seed the common set so there is always something to choose.
    private var allBinding: Binding<Bool> {
        Binding(
            get: { all },
            set: { on in
                if !on, enabled.isEmpty { enabled = PlayerSettings.commonLanguageCodes.sorted() }
                all = on
            }
        )
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(code) },
            set: { on in
                if on {
                    if !enabled.contains(code) { enabled.append(code); enabled.sort() }
                } else {
                    enabled.removeAll { $0 == code }
                }
            }
        )
    }
}

// MARK: - Rows

/// A toggle row with a leading icon and Cue pill switch (focus = fill + ring,
/// same treatment as every other settings row).
private struct PlaybackToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    /// Non-nil = this Apple TV can't do it. The row still shows (so the
    /// feature is discoverable and the limit is explained rather than
    /// mysterious) but reads as off and refuses to toggle.
    var unavailable: String?

    var body: some View {
        Button { if unavailable == nil { isOn.toggle() } } label: {
            PlaybackToggleLabel(
                icon: icon, title: title,
                subtitle: unavailable.map { "\(subtitle)\n\nUnavailable: \($0)." } ?? subtitle,
                isOn: isOn && unavailable == nil,
                dimmed: unavailable != nil
            )
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct PlaybackToggleLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool
    var dimmed = false

    var body: some View {
        HStack(alignment: .top, spacing: CueSpacing.md) {
            SettingsIconTile(symbol: icon)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)   // full text, wraps
                    .frame(maxWidth: 1000, alignment: .leading)
            }
            Spacer(minLength: CueSpacing.lg)
            CueSwitch(isOn: isOn)
                .padding(.top, 4)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, CueSpacing.md)
        .frame(minHeight: 76)
        .frame(maxWidth: .infinity)
        .background(SettingsRowBackground(isFocused: isFocused))
        .opacity(dimmed ? 0.5 : 1)
    }
}

