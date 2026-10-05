import SwiftUI

/// Settings categories, each a pushed pane on the Settings screen.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case account, tmdb, mdblist, appearance, homeContent, playback, about, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Nuvio"
        case .tmdb: return "TMDB"
        case .mdblist: return "MDBList"
        case .appearance: return "Appearance"
        case .homeContent: return "Home & Content"
        case .playback: return "Playback"
        case .about: return "About"
        case .developer: return "Developer"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "Your Nuvio account: syncing with your other devices, and your watch history."
        case .tmdb: return ServiceKey.tmdb.about
        case .mdblist: return ServiceKey.mdblist.about
        case .appearance: return "Background colour and the top bar"
        case .homeContent: return "Add-ons, Home's rows, Continue Watching and the Details page"
        case .playback: return "Player, audio and subtitles, sources"
        case .about: return "App information, updates, and legal links"
        case .developer: return "Render Lab, frame rate and performance switches"
        }
    }

    /// The accounts and keys, in their own section up top.
    static let accounts: [SettingsCategory] = [.account, .tmdb, .mdblist]

    /// Its pages' place, for the settings box (see `SettingsPlace`).
    var place: SettingsPlace { SettingsPlace(icon: icon, name: title, tint: tint) }

    /// Its symbol's colour (Apple's Settings give each its own), soft.
    var tint: Color {
        switch self {
        case .account: return Color(red: 0.35, green: 0.82, blue: 0.5)
        case .tmdb: return Color(red: 0.25, green: 0.8, blue: 0.85)
        case .mdblist: return Color(red: 1, green: 0.72, blue: 0.3)
        case .appearance: return Color(red: 0.75, green: 0.55, blue: 1)
        case .homeContent: return Color(red: 0.4, green: 0.65, blue: 1)
        case .playback: return Color(red: 1, green: 0.45, blue: 0.45)
        case .about: return Color(white: 0.8)
        case .developer: return Color(red: 0.55, green: 0.6, blue: 1)
        }
    }

    // SF Symbols matched to the APK's Material icons.
    var icon: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .tmdb: return "film.stack"
        case .mdblist: return "star.circle.fill"
        case .appearance: return "paintpalette.fill"
        case .homeContent: return "square.grid.2x2.fill"
        case .playback: return "play.fill"
        case .about: return "info.circle.fill"
        case .developer: return "gauge.with.dots.needle.67percent"
        }
    }
}

struct SettingsCategoryPane: View {
    let category: SettingsCategory

    var body: some View {
        switch category {
        case .account:      AccountSettingsDetail()
        case .tmdb:         TMDBServicePage()
        case .mdblist:      MDBListServicePage()
        case .appearance:   AppearanceSettingsDetail()
        case .homeContent:  HomeContentSettingsDetail()
        case .playback:     PlaybackSettingsDetail()
        case .about:        AboutDetail()
        case .developer:    DeveloperSettingsDetail()
        }
    }
}

/// Settings → Developer: Render Lab (the design's switches and the frame
/// rate), then the performance switches — one page.
struct DeveloperSettingsDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    @State private var syncLog = NuvioSyncDiagnostics.entries()
    @State private var showHealth = false

    var body: some View {
        DetailScaffold(title: SettingsCategory.developer.title, subtitle: SettingsCategory.developer.subtitle) {
            RenderLabSettings()
            PerformanceSettings()
            SettingsGroupCard(title: "Add-ons") {
                Button { showHealth = true } label: {
                    SettingsActionRow(
                        title: "Add-on Health",
                        subtitle: "Measure manifest response time and find slow or dead providers",
                        leadingIcon: "waveform.path.ecg"
                    )
                }
                .buttonStyle(PlainCardButtonStyle())
            }
            SettingsGroupCard(title: "MDBList", subtitle: "Its daily request limit, as its last answer reported it") {
                MDBListUsageLine(usage: MDBListUsage.shared)
            }
            // What account sync did recently — for when it misbehaves.
            SettingsGroupCard(title: "Sync log", subtitle: "Recent account sync events, newest first") {
                if syncLog.isEmpty {
                    Text("Nothing logged yet.")
                        .font(.system(size: 21))
                        .foregroundStyle(Color.white.opacity(0.6))
                } else {
                    ForEach(syncLog.prefix(20)) { SyncLogRow(entry: $0) }
                    Button("Clear log") {
                        NuvioSyncDiagnostics.clear()
                        syncLog = []
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showHealth) {
            AddonHealthView(onDone: { showHealth = false })
                .environmentObject(theme)
                .environmentObject(addonManager)
        }
    }
}

/// "412 of 1,000 left today · resets in 6 h · seen 2 min ago".
private struct MDBListUsageLine: View {
    @ObservedObject var usage: MDBListUsage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(text(now: context.date))
                .font(.system(size: 21))
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private func text(now: Date) -> String {
        guard let snapshot = usage.snapshot else {
            return "Nothing seen yet — shows after Cue's next MDBList request."
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        var parts = ["\(snapshot.remaining.formatted()) of \(snapshot.limit.formatted()) requests left"]
        if let resetsAt = snapshot.resetsAt {
            parts.append(resetsAt > now ? "resets \(relative.localizedString(for: resetsAt, relativeTo: now))"
                                        : "reset since")
        }
        parts.append("seen \(relative.localizedString(for: snapshot.seenAt, relativeTo: now))")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail scaffolding

/// A rounded, accent-tinted tile holding an SF Symbol. Gives every settings row
/// a consistent, scannable icon "chip" (iOS-Settings style) — the core visual
/// motif of the redesigned panes.
struct SettingsIconTile: View {
    @EnvironmentObject private var theme: ThemeManager
    let symbol: String
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [theme.palette.secondary.opacity(0.32), theme.palette.secondary.opacity(0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(theme.palette.secondary.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(theme.palette.secondary)
            )
            .frame(width: size, height: size)
    }
}

struct SettingsDetailHeader: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: CueSpacing.md) {
                // Accent spine — a bold vertical bar that anchors the title and
                // sets the new, more editorial header rhythm.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.palette.secondary)
                    .frame(width: 6, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 21))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped settings section rendered as a rounded card (title + optional
/// subtitle + rows), matching the APK's `secondaryCardRadius` (18dp) groups.
struct SettingsGroupCard<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var scheme
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: CueSpacing.sm) {
            // Section label sits ABOVE the card (grouped-list style) — the
            // accent-tinted, letter-spaced title reads as a real section break
            // instead of another boxed header stacked inside the card.
            if !title.isEmpty || (subtitle?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty {
                        Text(title.uppercased())
                            .font(.system(size: 18, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(theme.palette.secondary)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 19))
                            .foregroundStyle(theme.palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            }
            // The rows live in one shared surface; each row is flat until
            // focused, so the card groups them like a single list.
            VStack(spacing: 4) {
                content
            }
            .padding(CueSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.settingsCardRadius, style: .continuous)
                    .fill(theme.palette.backgroundCard.opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.settingsCardRadius, style: .continuous)
                    // Hairline reads mid-grey on dark; in ATV light mode that
                    // same grey is a heavy outline — use a soft dark line.
                    .strokeBorder(scheme == .light ? Color.black.opacity(0.10)
                                  : CuePrimitives.neutral750.opacity(0.55), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tappable settings row with strong focus, matching the Android SettingsActionRow.
struct SettingsActionRow: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    var subtitle: String?
    var value: String?
    var leadingIcon: String?

    var body: some View {
        HStack(spacing: CueSpacing.md) {
            if let leadingIcon {
                SettingsIconTile(symbol: leadingIcon)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            Spacer(minLength: CueSpacing.lg)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(theme.palette.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFocused ? theme.palette.textSecondary : theme.palette.textTertiary)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, CueSpacing.md)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity)
        .background(SettingsRowBackground(isFocused: isFocused))
        // Was a spring, so one row type bounced while the value row directly
        // beneath it eased. One focus response for the whole app.
        .animation(perf.motion(FusionFocus.liftAnimation), value: isFocused)
    }
}

/// Shared row backdrop for the redesigned settings: transparent when idle so
/// rows read as one grouped list, and an accent-tinted, ringed highlight when
/// focused. No per-row scale — the fill/ring alone carries focus.
struct SettingsRowBackground: View {
    @EnvironmentObject private var theme: ThemeManager
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
            .fill(isFocused ? theme.palette.focusBackground : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 3)
            )
    }
}

struct DetailScaffold<Content: View>: View {
    @EnvironmentObject private var theme: ThemeManager
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: CueSpacing.xl) {
                SettingsDetailHeader(title: title, subtitle: subtitle)
                    .padding(.bottom, CueSpacing.xs)
                content
            }
            .padding(.horizontal, CueSpacing.xl)
            .padding(.top, CueSpacing.lg)
            .padding(.bottom, CueSpacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Clips scrolled content to the pane so rows stay inside the workspace card.
    }
}

struct CueSwitch: View {
    @EnvironmentObject private var theme: ThemeManager
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                // `.primary` == white under Classic's forced-dark scheme;
                // flips to a visible dark track in ATV light mode.
                .fill(isOn ? theme.palette.secondary : Color.primary.opacity(0.18))
                .frame(width: 64, height: 36)
            Circle()
                // The knob has to read against TWO different tracks: the dark
                // off-track and the accent on-track. A hardcoded white knob
                // vanished on the White theme, whose accent track is white too
                // — the "toggles are invisible with the white colour" report.
                // `onSecondary` is the accent's own ink (dark on White), so the
                // knob contrasts when on; white is right for the dark off-track.
                .fill(isOn ? theme.palette.onSecondary : .white)
                .frame(width: 28, height: 28)
                .padding(4)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
    }
}

/// A toggle row rendered as a focusable card (title + subtitle + pill switch),
/// matching the APK's toggle rows.
struct SettingsToggleCard: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            ToggleCardLabel(title: title, subtitle: subtitle, isOn: isOn)
        }
        .buttonStyle(PlainCardButtonStyle())
    }
}

private struct ToggleCardLabel: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let subtitle: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: CueSpacing.lg) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 18))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            CueSwitch(isOn: isOn)
        }
        .padding(.horizontal, CueSpacing.lg)
        .frame(minHeight: 68)
        .background(
            RoundedRectangle(cornerRadius: theme.settingsRowRadius, style: .continuous)
                .fill(isFocused ? theme.palette.focusBackground : theme.palette.backgroundCard.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.settingsRowRadius, style: .continuous)
                .strokeBorder(isFocused ? theme.palette.focusRing : .clear, lineWidth: 4)
        )
    }
}

/// A navigation-style row with a trailing value + chevron. Focus = brighter
/// fill + thick accent ring so the selected row is always unmistakable.
struct SettingsValueCard: View {
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isFocused) private var isFocused
    let title: String
    let subtitle: String
    let value: String
    var icon: String = "puzzlepiece.extension.fill"

    var body: some View {
        HStack(spacing: CueSpacing.md) {
            SettingsIconTile(symbol: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(subtitle).font(.system(size: 20))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: CueSpacing.lg)
            Text(value).font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.palette.secondary)
            Image(systemName: "chevron.right").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFocused ? theme.palette.textSecondary : theme.palette.textTertiary)
        }
        .padding(.horizontal, CueSpacing.md)
        .padding(.vertical, CueSpacing.md)
        .frame(minHeight: 72)
        .background(SettingsRowBackground(isFocused: isFocused))
        .animation(perf.motion(FusionFocus.liftAnimation), value: isFocused)
    }
}

// MARK: - Add-ons detail

/// Content & Discovery — the APK folds add-ons, catalogs and collections into
/// one section, so this pane hosts add-on management plus a Collections entry.
/// Content & Discovery pane: a single "Addons" drill-in row (APK behavior).
/// Settings → Playback → Sources → Badges: Badger badge-pack import —
/// paste a config URL (from the Badger editor's export / a community
/// template), fetch + validate, show the live state, and allow removal. The
/// chips then appear on Sources-page rows.
struct StreamBadgeSettings: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    @State private var badgeURLInput = ""
    @State private var badgeImporting = false

    var body: some View { badgeControls }

    @ViewBuilder
    private var badgeControls: some View {
        if streamBadges.isConfigured {
            HStack(spacing: CueSpacing.md) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.palette.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(streamBadges.filterCount) badge filters active")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(streamBadges.sourceURL)
                        .font(.system(size: 17))
                        .foregroundStyle(theme.palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Sync from Account") {
                    Task { await streamBadges.syncFromAccount() }
                }
                .font(.system(size: 22, weight: .semibold))
                Button("Remove") { streamBadges.removeConfig() }
                    .font(.system(size: 22, weight: .semibold))
            }
            .padding(.vertical, 4)
            badgeExtraControls
            if let status = streamBadges.lastStatus {
                Text(status)
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        } else {
            HStack(spacing: CueSpacing.md) {
                TextField("Badge config URL or Pastebin link", text: $badgeURLInput)
                    .font(.system(size: 22))
                Button {
                    guard !badgeImporting, !badgeURLInput.isEmpty else { return }
                    badgeImporting = true
                    Task {
                        await streamBadges.importConfig(from: badgeURLInput)
                        badgeImporting = false
                        if streamBadges.isConfigured { badgeURLInput = "" }
                    }
                } label: {
                    if badgeImporting {
                        ProgressView()
                    } else {
                        Text("Import")
                            .font(.system(size: 22, weight: .semibold))
                    }
                }
            }
            Button("Sync from Account") {
                Task { await streamBadges.syncFromAccount() }
            }
            .font(.system(size: 22, weight: .semibold))

            badgeExtraControls
            if let status = streamBadges.lastStatus {
                Text(status)
                    .font(.system(size: 19))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Text("Build or pick a badge pack at nintle.github.io/Badger, host the JSON (the editor gives you a link), and paste its URL here — or pull the pack already set up in another Cue app with Sync from Account.")
                .font(.system(size: 18))
                .foregroundStyle(theme.palette.textTertiary)
        }
    }

    /// Size + profile pickers, shown in BOTH the configured and empty states.
    @ViewBuilder
    private var badgeExtraControls: some View {
        CueDropdown(
            title: "Badge size",
            icon: "textformat.size",
            selection: streamBadges.sizeRawUI,
            options: StreamBadgeStore.sizeOptions.map { CueDropdownOption($0.0, $0.1) }
        ) { streamBadges.setSize($0) }

        // Only when the account carries badge configs from 2+ Nuvio apps —
        // run Sync from Account once to discover them.
        if !streamBadges.remoteProfiles.isEmpty {
            CueDropdown(
                title: "Badge profile",
                icon: "person.2",
                selection: streamBadges.preferredRemoteProfileID.isEmpty
                    ? streamBadges.remoteProfiles[0].id
                    : streamBadges.preferredRemoteProfileID,
                options: streamBadges.remoteProfiles.map { CueDropdownOption($0.id, $0.label) }
            ) { id in
                streamBadges.preferredRemoteProfileID = id
                streamBadges.applyChosenRemoteProfile()
            }
        }
    }
}

/// Full-screen Collections manager, opened from Home & Content. Menu/Back
/// closes it back to the settings pane.
private struct CollectionsCoverView: View {
    @EnvironmentObject private var theme: ThemeManager
    let onDone: () -> Void

    var body: some View {
        ZStack {
            ATVBackground()
            CollectionsSettingsDetail()
                .padding(.horizontal, CueSpacing.xxl)
                .padding(.vertical, CueSpacing.xl)
        }
        .onExitCommand { onDone() }
    }
}

struct AboutDetail: View {
    @EnvironmentObject private var theme: ThemeManager
    @State private var info: AboutInfo?
    // Starts empty and is filled by .task below. The default value used to be
    // `DiagnosticsService.cacheSizeLabel()`, which walks the whole cache
    // directory synchronously on the main thread — and a @State default is
    // evaluated every time the view struct is built, not once, so opening
    // About (and every redraw of it) stuttered.
    @State private var cacheLabel = "…"
    @State private var clearing = false

    var body: some View {
        DetailScaffold(title: SettingsCategory.about.title, subtitle: SettingsCategory.about.subtitle) {
            SettingsGroupCard(title: "") {
                VStack(spacing: CueSpacing.sm) {
                    HStack(spacing: CueSpacing.sm) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(theme.palette.secondary)
                        Text("CUE")
                            .font(.system(size: 40, weight: .heavy))
                            .foregroundStyle(theme.palette.textPrimary)
                    }
                    Text("Version \(DiagnosticsService.appVersion)")
                        .font(.system(size: 18))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, CueSpacing.md)

                Button { info = .privacy } label: {
                    SettingsValueCard(title: "Privacy Policy", subtitle: "View our privacy policy", value: "", icon: "hand.raised.fill")
                }.buttonStyle(PlainCardButtonStyle())
                Button { info = .licenses } label: {
                    SettingsValueCard(title: "Licenses & Attributions", subtitle: "Open-source components used in this app", value: "", icon: "doc.text.fill")
                }.buttonStyle(PlainCardButtonStyle())
            }

            SettingsGroupCard(title: "Diagnostics", subtitle: "Device information and storage") {
                SettingsValueCard(title: "System", subtitle: DiagnosticsService.deviceModel, value: DiagnosticsService.systemVersion, icon: "appletv.fill")
                Button {
                    guard !clearing else { return }
                    clearing = true
                    // Off the main thread for the same reason as the initial
                    // measurement: clearing and re-measuring both enumerate the
                    // cache directory recursively.
                    Task {
                        await Task.detached(priority: .userInitiated) {
                            DiagnosticsService.clearCaches()
                        }.value
                        cacheLabel = await Self.measureCache()
                        clearing = false
                    }
                } label: {
                    SettingsValueCard(
                        title: "Clear cache",
                        subtitle: "Remove cached source lists, metadata and images",
                        value: clearing ? "…" : cacheLabel,
                        icon: "trash.fill"
                    )
                }.buttonStyle(PlainCardButtonStyle())
            }
        }
        .task {
            // Measure the cache once the view is on screen, off the main
            // thread — see cacheLabel above.
            cacheLabel = await Self.measureCache()
        }
        .fullScreenCover(item: $info) { item in
            AboutInfoView(info: item)
                .environmentObject(theme)
        }
    }

    private static func measureCache() async -> String {
        await Task.detached(priority: .utility) {
            DiagnosticsService.cacheSizeLabel()
        }.value
    }
}

/// The static info pages reachable from About.
private enum AboutInfo: String, Identifiable {
    case privacy, licenses
    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return "Privacy Policy"
        case .licenses: return "Licenses & Attributions"
        }
    }

    var body: String {
        switch self {
        case .privacy:
            return "Cue does not collect, store, or share any personal data. All playback, library, and account information stays on your device or with the third-party services you explicitly connect (such as TMDB, Trakt, or your debrid provider). No analytics or tracking is performed by this app."
        case .licenses:
            return "This app uses open-source components including SwiftUI, KSPlayer, and metadata provided by TMDB. TMDB is used under their API terms; this product uses the TMDB API but is not endorsed or certified by TMDB. Full license texts for bundled components are available in the source repository."
        }
    }
}

private struct AboutInfoView: View {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    let info: AboutInfo

    var body: some View {
        DetailScaffold(title: info.title, subtitle: "") {
            SettingsGroupCard(title: "") {
                Text(info.body)
                    .font(.system(size: 22))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CueSpacing.md)
            }
        }
        .onExitCommand { dismiss() }
    }
}

private struct AddonHealthView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var addonManager: AddonManager
    let onDone: () -> Void

    @State private var scanning = false
    @State private var results: [AddonManager.HealthResult] = []

    var body: some View {
        ZStack {
            ATVBackground()
            DetailScaffold(title: "Add-on Health", subtitle: "Manifest response times for installed providers") {
                SettingsGroupCard(title: "Scan", subtitle: summary) {
                    Button { scan() } label: {
                        SettingsActionRow(
                            title: scanning ? "Scanning..." : "Run Health Check",
                            subtitle: "Checks installed manifest URLs without changing your setup",
                            value: scanning ? "..." : nil,
                            leadingIcon: "waveform.path.ecg"
                        )
                    }
                    .buttonStyle(PlainCardButtonStyle())
                    .disabled(scanning)
                }

                if !results.isEmpty {
                    SettingsGroupCard(title: "Results") {
                        ForEach(results) { result in
                            AddonHealthRow(
                                result: result,
                                onDisable: { disable(result) }
                            )
                        }
                    }
                }
            }
        }
        .task {
            if results.isEmpty { scan() }
        }
        .onExitCommand(perform: onDone)
    }

    private var summary: String {
        guard !results.isEmpty else {
            return scanning ? "Checking installed add-ons..." : "No scan has run yet"
        }
        let failed = results.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        let slow = results.filter { $0.status == .slow }.count
        if failed > 0 || slow > 0 {
            return "\(failed) failed, \(slow) slow, \(results.count) checked"
        }
        return "All \(results.count) installed add-ons responded normally"
    }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            results = await addonManager.healthCheck().sorted { lhs, rhs in
                rank(lhs.status) < rank(rhs.status)
            }
            scanning = false
        }
    }

    private func rank(_ status: AddonManager.HealthResult.Status) -> Int {
        switch status {
        case .failed: return 0
        case .slow: return 1
        case .ok: return 2
        case .disabled: return 3
        }
    }

    private func disable(_ result: AddonManager.HealthResult) {
        guard let addon = addonManager.addons.first(where: { $0.id == result.id }) else { return }
        addonManager.setEnabled(addon, false)
        scan()
    }
}

private struct AddonHealthRow: View {
    @EnvironmentObject private var theme: ThemeManager
    let result: AddonManager.HealthResult
    let onDisable: () -> Void

    var body: some View {
        HStack(spacing: CueSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 56, height: 56)
                .background(Circle().fill(color.opacity(0.16)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: CueSpacing.sm) {
                    Text(result.name)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(result.status.label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.16)))
                }
                Text(detail)
                    .font(.system(size: 18))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2)
                Text(result.manifestURL)
                    .font(.system(size: 16).monospaced())
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if canDisable {
                Button("Disable", action: onDisable)
                    .font(.system(size: 21, weight: .semibold))
            }
        }
        .padding(.horizontal, CueSpacing.lg)
        .padding(.vertical, CueSpacing.sm)
        .background(theme.palette.backgroundCard.opacity(0.5), in: RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous))
    }

    private var detail: String {
        let timing = result.elapsedMS.map { "\($0) ms" } ?? "not checked"
        switch result.status {
        case .failed(let reason):
            return "\(result.capabilities) · \(timing) · \(reason)"
        default:
            return "\(result.capabilities) · \(timing)"
        }
    }

    private var canDisable: Bool {
        switch result.status {
        case .failed, .slow: return true
        case .ok, .disabled: return false
        }
    }

    private var icon: String {
        switch result.status {
        case .ok: return "checkmark.circle.fill"
        case .slow: return "speedometer"
        case .disabled: return "pause.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch result.status {
        case .ok: return CuePrimitives.success
        case .slow: return theme.palette.secondary
        case .disabled: return theme.palette.textTertiary
        case .failed: return CuePrimitives.error
        }
    }
}
