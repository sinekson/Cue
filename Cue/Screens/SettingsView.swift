import SwiftUI

/// Settings categories, each a pushed pane on the Settings screen.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case account, tmdb, mdblist, appearance, homeContent, playback, storage, about, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Nuvio"
        case .tmdb: return "TMDB"
        case .mdblist: return "MDBList"
        case .appearance: return "Appearance"
        case .homeContent: return "Home & Details"
        case .playback: return "Playback"
        case .storage: return "Storage"
        case .about: return "About"
        case .developer: return "Developer"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "Keeps your profiles, add-ons and watch progress in sync across your devices."
        case .tmdb: return ServiceKey.tmdb.about
        case .mdblist: return ServiceKey.mdblist.about
        case .appearance: return "Change how Cue's pages and cards look."
        case .homeContent: return "Choose what Home shows and how titles behave."
        case .playback: return "Choose the language titles play in."
        case .storage: return "See what Cue keeps on this Apple TV and clear it."
        case .about: return "See Cue's version, privacy and licenses."
        case .developer: return "Test Cue's rendering and performance."
        }
    }

    /// Its symbol on Settings' tile, on its pages (the categories: the play).
    var symbol: String {
        switch self {
        case .account: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .tmdb: return "photo.badge.magnifyingglass"
        case .mdblist: return "hand.thumbsup"
        case .appearance: return "paintpalette"
        case .homeContent: return "rectangle.grid.3x1"
        case .playback: return "playpause"
        case .storage: return "internaldrive"
        case .about: return "info.circle"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The accounts and keys, in their own section up top.
    static let accounts: [SettingsCategory] = [.account, .tmdb, .mdblist]
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
        case .storage:      StorageSettingsDetail()
        case .about:        AboutDetail()
        case .developer:    DeveloperSettingsDetail()
        }
    }
}

/// Settings → Developer: the frame rate, then the diagnostics — one page.
struct DeveloperSettingsDetail: View {
    @EnvironmentObject private var addonManager: AddonManager
    @State private var syncLog = NuvioSyncDiagnostics.entries()
    @State private var showHealth = false

    var body: some View {
        DetailScaffold(title: SettingsCategory.developer.title, subtitle: "") {
            MeasureSettings()
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

                .environmentObject(addonManager)
        }
    }
}

// MARK: - Detail scaffolding

/// A rounded, accent-tinted tile holding an SF Symbol. Gives every settings row
/// a consistent, scannable icon "chip" (iOS-Settings style) — the core visual
/// motif of the redesigned panes.
struct SettingsIconTile: View {
    let symbol: String
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [CuePalette.secondary.opacity(0.32), CuePalette.secondary.opacity(0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(CuePalette.secondary.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(CuePalette.secondary)
            )
            .frame(width: size, height: size)
    }
}

struct SettingsDetailHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: CueSpacing.md) {
                // Accent spine — a bold vertical bar that anchors the title and
                // sets the new, more editorial header rhythm.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(CuePalette.secondary)
                    .frame(width: 6, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(CuePalette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 21))
                        .foregroundStyle(CuePalette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped settings section rendered as a rounded card (title + optional
/// subtitle + rows), matching the APK's `secondaryCardRadius` (18dp) groups.
struct SettingsGroupCard<Content: View>: View {
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
                            .foregroundStyle(CuePalette.secondary)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 19))
                            .foregroundStyle(CuePalette.textTertiary)
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(CuePalette.backgroundCard.opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
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
                    .foregroundStyle(CuePalette.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(CuePalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }
            Spacer(minLength: CueSpacing.lg)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(CuePalette.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFocused ? CuePalette.textSecondary : CuePalette.textTertiary)
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
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
            .fill(isFocused ? CuePalette.focusBackground : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? CuePalette.focusRing : .clear, lineWidth: 3)
            )
    }
}

struct DetailScaffold<Content: View>: View {
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
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? CuePalette.secondary : Color.primary.opacity(0.18))
                .frame(width: 64, height: 36)
            Circle()
                // The knob has to read against TWO different tracks: the dark
                // off-track and the accent on-track. A hardcoded white knob
                // vanished on the White theme, whose accent track is white too
                // — the "toggles are invisible with the white colour" report.
                // `onSecondary` is the accent's own ink (dark on White), so the
                // knob contrasts when on; white is right for the dark off-track.
                .fill(isOn ? CuePalette.onSecondary : .white)
                .frame(width: 28, height: 28)
                .padding(4)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isOn)
    }
}

/// Storage: what Cue keeps on this Apple TV — the cache and the search
/// history, each a page with what it holds and its clear — and the space
/// left. No confirmations.
struct StorageSettingsDetail: View {
    @EnvironmentObject private var search: SearchViewModel
    @State private var total: Int64?
    @State private var free: Int64?

    var body: some View {
        SettingsPage(title: SettingsCategory.storage.title,
                     subtitle: "What Cue keeps on this Apple TV.") {
            SettingsSection {
                SettingsLinkRow(title: "Cache", value: total.map(CachePage.size)) {
                    CachePage(measured: { total = $0 })
                }
                SettingsLinkRow(title: "Search History",
                                value: search.hasHistory ? nil : "Empty") { SearchHistoryPage() }
            }
            SettingsSection {
                VStack(spacing: 0) {
                    SettingsInfoRow(title: "Free on This Apple TV", value: free.map(CachePage.size) ?? "—")
                }
            }
        }
        .task {
            total = await CacheStorage.measure().reduce(0) { $0 + $1.bytes }
            free = CacheStorage.available()
        }
    }
}

/// Every cache by kind with its size and allowance, and one clear for all
/// of it (`CacheStorage`): everything here loads again as needed.
private struct CachePage: View {
    /// The total, back to Storage's row.
    let measured: (Int64) -> Void
    @State private var parts: [CacheStorage.Part] = []
    @State private var done = false
    @State private var clearing = false

    var body: some View {
        SettingsPage(title: "Cache",
                     subtitle: "Cue keeps pictures and title details on this Apple TV so pages open at once. "
                        + "Clearing them is safe: they load again as needed.") {
            SettingsSection {
                SettingsButtonRow(title: "Clear Cache",
                                  description: "Removes everything below. Your account, profiles, progress, "
                                    + "library and settings stay.",
                                  value: clearing ? "Clearing…" : (done ? Self.size(total) : nil)) {
                    clear()
                }
            }
            SettingsSection(title: "Cache") {
                VStack(spacing: 0) {
                    ForEach(parts) { part in
                        SettingsInfoRow(title: part.name, value: Self.value(part))
                    }
                }
            }
        }
        .task { await measure() }
    }

    private var total: Int64 { parts.reduce(0) { $0 + $1.bytes } }

    private func measure() async {
        parts = await CacheStorage.measure()
        done = true
        measured(total)
    }

    private func clear() {
        guard !clearing else { return }
        clearing = true
        Task {
            await CacheStorage.clear()
            await measure()
            clearing = false
        }
    }

    static func size(_ bytes: Int64) -> String {
        bytes == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private static func value(_ part: CacheStorage.Part) -> String {
        guard let limit = part.limit else { return size(part.bytes) }
        let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
        return part.bytes == 0 ? "Empty, up to \(limitText)" : "\(size(part.bytes)) of \(limitText)"
    }
}

/// This profile's recent searches (under Search's keyboard) and the titles
/// opened from Search (its row before you type), and one clear for both.
private struct SearchHistoryPage: View {
    @EnvironmentObject private var search: SearchViewModel

    var body: some View {
        SettingsPage(title: "Search History",
                     subtitle: "What this profile searched for, and the titles it opened from Search.") {
            SettingsSection {
                SettingsButtonRow(title: "Clear Search History",
                                  description: "Removes the searches and titles below.",
                                  value: search.hasHistory ? nil : "Empty") {
                    search.clearHistory()
                }
            }
            if !search.recentSearches.isEmpty {
                SettingsSection(title: "Searches") {
                    VStack(spacing: 0) {
                        ForEach(search.recentSearches, id: \.self) { SettingsInfoRow(title: $0, value: "") }
                    }
                }
            }
            if !search.recentTitles.isEmpty {
                SettingsSection(title: "Titles") {
                    VStack(spacing: 0) {
                        ForEach(search.recentTitles, id: \.id) { item in
                            SettingsInfoRow(title: item.name,
                                            value: item.type == "movie" ? "Movie" : "Series")
                        }
                    }
                }
            }
        }
    }
}

/// About: what's behind Cue, then what's only to read. Pressing leads to
/// Privacy and Licenses & Credits, in the column.
struct AboutDetail: View {
    var body: some View {
        SettingsPage(title: SettingsCategory.about.title) {
            SettingsSection {
                SettingsLinkRow(title: "Privacy") { AboutPrivacyPage() }
                SettingsLinkRow(title: "Licenses & Credits") { AboutLicensesPage() }
                VStack(spacing: 0) {
                    SettingsInfoRow(title: "Version", value: DiagnosticsService.appVersion)
                    SettingsInfoRow(title: "Device", value: DiagnosticsService.deviceName)
                    SettingsInfoRow(title: "Software", value: DiagnosticsService.systemVersion)
                    SettingsInfoRow(title: "Source Code", value: DiagnosticsService.sourceAddress)
                }
                .padding(.top, SettingsMetrics.infoGap)
            }
        }
    }
}

/// Running text on a page of its own, lined up with the rows' text.
private struct AboutText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: SettingsMetrics.descriptionTextSize))
            .foregroundStyle(Color.white.opacity(FixedFocusText.body))
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SettingsMetrics.rowInset)
    }
}

/// Only to read: focus stays on the page, unseen.
private struct AboutPrivacyPage: View {
    var body: some View {
        SettingsPage(title: "Privacy") {
            SettingsSection {
                AboutText("Cue collects nothing about you and has no analytics or tracking.")
                AboutText("It talks only to the services it needs: Nuvio to sync your account, "
                    + "TMDB for search and details, MDBList for ratings if you add a key, the add-ons "
                    + "you installed for titles and sources, and YouTube for trailers.")
                AboutText("What those services receive is covered by their own privacy policies.")
            }
            .background(alignment: .top) { SettingsFocusHolder() }
        }
    }
}

private struct AboutLicensesPage: View {
    var body: some View {
        SettingsPage(title: "Licenses & Credits") {
            SettingsSection {
                AboutText("Cue is free software under the GNU General Public License, version 3. "
                    + "Its source code is at \(DiagnosticsService.sourceAddress).")
            }
            .background(alignment: .top) { SettingsFocusHolder() }
            SettingsSection(title: "Built With") {
                VStack(spacing: 0) {
                    SettingsInfoRow(title: "AetherEngine", value: "LGPLv3")
                    SettingsInfoRow(title: "FFmpeg", value: "LGPLv2.1")
                    SettingsInfoRow(title: "libass", value: "ISC")
                    SettingsInfoRow(title: "Inter", value: "SIL OFL 1.1")
                    SettingsInfoRow(title: "FriBidi", value: "LGPLv2.1")
                    SettingsInfoRow(title: "HarfBuzz", value: "MIT")
                    SettingsInfoRow(title: "FreeType", value: "FTL")
                    SettingsInfoRow(title: "Fontconfig", value: "MIT")
                    SettingsInfoRow(title: "YouTubeKit", value: "MIT")
                    SettingsInfoRow(title: "libdovi", value: "MIT")
                }
            }
            SettingsSection {
                AboutText("This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }
        }
    }
}

private struct AddonHealthView: View {
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
                        .foregroundStyle(CuePalette.textPrimary)
                    Text(result.status.label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.16)))
                }
                Text(detail)
                    .font(.system(size: 18))
                    .foregroundStyle(CuePalette.textSecondary)
                    .lineLimit(2)
                Text(result.manifestURL)
                    .font(.system(size: 16).monospaced())
                    .foregroundStyle(CuePalette.textTertiary)
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
        .background(CuePalette.backgroundCard.opacity(0.5), in: RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous))
    }

    private var detail: String {
        let timing = result.elapsedMS.map { "\($0) ms" } ?? "not checked"
        switch result.status {
        case .failed(let reason):
            return "\(result.capabilities), \(timing), \(reason)"
        default:
            return "\(result.capabilities), \(timing)"
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
        case .slow: return CuePalette.secondary
        case .disabled: return CuePalette.textTertiary
        case .failed: return CuePrimitives.error
        }
    }
}
