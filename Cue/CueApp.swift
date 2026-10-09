import AVKit
import SwiftUI

@main
struct CueApp: App {
    /// Reclaim orphaned player scratch space before anything else runs. A
    /// remux session that got jetsammed leaves its segment directory behind
    /// with no owner left to delete it, and nothing else in the app ever
    /// swept them — launch is the one moment we know none of them are live.
    init() {
        // FIRST of all, before ANY UserDefaults write below: shrink an
        // oversized add-on blob a pre-compression build left behind. On a box
        // already at the ~1 MB CFPreferences abort, the first unrelated write
        // (the migration stamp, a store save) aborts the process, so the app
        // crash-loops on launch and the viewer can never reach Settings to
        // remove the add-on. This is a reducing write, which CFPreferences
        // accepts, so it breaks the loop. See AddonManager.
        AddonManager.reclaimUncompressedStorage()
        // Same emergency reclaim for the content stores. A large SIMKL/Trakt
        // import can put the watched history or the library past the ~1 MB
        // CFPreferences abort on its own, and on such a box the first save
        // crash-loops the app before it can ever compress — so shrink those
        // blobs here, first. Both namespaces: the rename migration below would
        // otherwise copy an oversized `nuvio.*` blob into `cue.*`.
        StoreBlob.reclaim(prefixes: ["cue.watched.v1", "cue.library.v1",
                                     "nuvio.watched.v1", "nuvio.library.v1"])
        #if !DEBUG
        // A pre-v8 release build persisted an unbounded PiP dev trail (measured
        // ~97 KB, the single largest key in the domain) that the PiP code only
        // clears once PiP actually runs. Clear it here so a viewer who never
        // opens PiP still reclaims the space before the domain can reach the
        // abort.
        UserDefaults.standard.removeObject(forKey: "dev.pipTrail")
        #endif
        PlayerTempSweep.sweepAtLaunch()
        // Diagnostics capture (Settings → Performance). Resolved BEFORE any
        // probe starts so a Release install can be probed without a Debug
        // rebuild: DEBUG defaults on, Release defaults off, and the stored
        // choice wins either way.
        ProbeGate.configureFromDefaults()
        // LAN read-out of the probe bus, so a session can be watched live
        // without `devicectl` backgrounding the app mid-playback.
        ColorProbeServer.shared.start()
        // …and a recording that SURVIVES the failure, for when the live probe
        // cannot answer: a suspended app, a wedged one, or a box that panics.
        // See FlightRecorder for what it records and why each field is there.
        FlightRecorder.start()
        // The browse half of the same probe. Armed HERE, not on a screen's
        // appear, so the tail covers launch itself — a cold start that hangs
        // before any view exists is exactly the session with no other witness.
        AppProbe.installLevels()
    }

    @StateObject private var theme = ThemeManager()
    @StateObject private var addonManager = AddonManager()
    @StateObject private var progressStore = ProgressStore()
    @StateObject private var account = NuvioAccountManager()
    @StateObject private var library = LibraryStore()
    @StateObject private var watched = WatchedStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var collections = CollectionsStore()
    @StateObject private var homeCatalogSettings = HomeCatalogSettingsStore()
    @StateObject private var tmdbSettings = TMDBSettingsStore()
    @StateObject private var mdblistSettings = MDBListSettingsStore()
    @StateObject private var playerSettings = PlayerSettingsStore()
    @StateObject private var streamBadges = StreamBadgeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .fontDesign(theme.rootFontDesign)   // app-wide font family (Fusion routes serif to headings only)
                .environmentObject(theme)
                .environmentObject(addonManager)
                .environmentObject(progressStore)
                .environmentObject(account)
                .environmentObject(library)
                .environmentObject(watched)
                .environmentObject(profiles)
                .environmentObject(collections)
                .environmentObject(homeCatalogSettings)
                .environmentObject(tmdbSettings)
                .environmentObject(mdblistSettings)
                .environmentObject(playerSettings)
                .environmentObject(streamBadges)
                // Classic is hard-dark (the original look). The Apple TV theme
                // honors its Appearance setting — light, dark, or nil to
                // follow the TV's own system appearance.
                .preferredColorScheme(theme.preferredColorScheme)
        }
    }
}

/// Human names for the probe's `[app]` block and its nav events. Kept beside
/// the enum so a new case is obvious here too — an unnamed route reads as
/// "route" in the tail and tells the reader nothing.
extension Route {
    var probeName: String {
        switch self {
        case .detail: return "Detail"
        case .collection: return "Collection"
        case .folder: return "Folder"
        case .folderPart: return "Folder Part"
        case .person: return "Cast"
        case .tmdbCompany: return "Studio"
        case .catalogSeeAll: return "See All"
        case .streams: return "Sources"
        case .streamsFromStart: return "Sources (from start)"
        case .streamsResume: return "Sources (resume)"
        }
    }

    var probeDetail: String {
        switch self {
        case .detail(let item): return "\(item.name) [\(item.type) \(item.id)]"
        case .collection(let c): return c.title
        case .folder(let c, let f): return "\(c.title) → \(f.title)"
        case .folderPart(let c, let f, let part): return "\(c.title) → \(f.title) → \(part)"
        case .person(_, let name): return name
        case .tmdbCompany(_, let name, _): return name
        case .catalogSeeAll(_, _, let title): return title
        case .streams(let meta, let video),
             .streamsFromStart(let meta, let video),
             .streamsResume(let meta, let video, _):
            return meta.name + (video.map { " S\($0.season ?? 0)E\($0.episode ?? 0)" } ?? "")
        default: return ""
        }
    }
}

enum Route: Hashable {
    case detail(MetaItem)
    case streams(MetaItem, MetaVideo?)
    /// Source picker that plays from 0:00 (the Detail page's Start Over).
    case streamsFromStart(MetaItem, MetaVideo?)
    /// Continue Watching resume: re-scrape fresh sources and auto-play the one
    /// matching what was last watched. `fromStart` plays it from 0:00 (Start
    /// Over) instead of the saved position.
    case streamsResume(MetaItem, MetaVideo?, fromStart: Bool)
    case collection(CueCollection)
    /// A folder of a collection, opened from its Home row.
    case folder(CueCollection, CueCollectionFolder)
    /// One catalog of a folder, in full (its part's "See All").
    case folderPart(CueCollection, CueCollectionFolder, String)
    case person(id: Int, name: String)
    /// A studio's titles — or a network's (`network`), its shows.
    case tmdbCompany(id: Int, name: String, network: Bool = false)
    case catalogSeeAll(addon: InstalledAddon, catalog: ManifestCatalog, title: String)
}

struct RootView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var modeSwap = ModeSwap.shared
    @ObservedObject private var sourcePicker = SourcePicker.shared
    @ObservedObject private var launcher = PlayLauncher.shared
    @ObservedObject private var perf = PerformanceSettingsStore.shared
    @EnvironmentObject private var addonManager: AddonManager
    @EnvironmentObject private var progressStore: ProgressStore
    @EnvironmentObject private var account: NuvioAccountManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watched: WatchedStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var collections: CollectionsStore
    @EnvironmentObject private var homeCatalogSettings: HomeCatalogSettingsStore
    @EnvironmentObject private var playerSettings: PlayerSettingsStore
    @EnvironmentObject private var streamBadges: StreamBadgeStore
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @Environment(\.scenePhase) private var scenePhase

    // One navigation stack per tab (tvOS expects TabView at the top level with
    // an independent NavigationStack inside each tab; a shared stack under one
    // NavigationStack makes the tab bar hard to reach and focus feel stuck).
    @State private var homePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var moviesPath = NavigationPath()
    @State private var seriesPath = NavigationPath()

    /// The navigation stack of the Home-like tab in front (Home, Movies,
    /// Series): plays and sources opened from its rows are pushed there.
    private var homeLikePath: Binding<NavigationPath> {
        switch selectedTab {
        case AppTab.movies.rawValue: return $moviesPath
        case AppTab.series.rawValue: return $seriesPath
        default: return $homePath
        }
    }

    private var onHomeLikeTab: Bool { AppTab(rawValue: selectedTab)?.isHomeLike ?? false }
    // Persisted here (not inside HomeView) so switching tabs and coming back
    // doesn't rebuild it and re-trigger the catalog load / loading spinner.
    @StateObject private var homeViewModel = HomeViewModel()
    // Persisted here (not inside SearchView) so leaving the Search tab and
    // coming back keeps the query and results instead of clearing them.
    @StateObject private var searchViewModel = SearchViewModel()
    @State private var playback: PlaybackRequest?
    /// An Auto Link Selector auto-play is on screen; pop its source page once the
    /// player closes so Back returns to the title page, not the source list.
    /// Deferred (not popped at play time) so StreamsView isn't torn down while
    /// its resolve Task is still running.
    @State private var pendingAutoPlayPop = false
    /// A deep-link add-on install waiting for the viewer to say yes.
    ///
    /// A `stremio://` / `https://…/manifest.json` / `cue://<host>` link used
    /// to install SILENTLY (a bare `Task { try? await install(…) }` — no prompt,
    /// no toast, error swallowed). Anything on the network that can make tvOS
    /// open a URL — another app, a QR code, an AirPlay handoff — could add a
    /// stream provider that then feeds this app arbitrary stream URLs. Now the
    /// manifest is fetched first (read-only), the add-on is NAMED in a
    /// confirmation, and nothing is written until the viewer presses Install.
    @State private var pendingAddonInstall: PendingAddonInstall?
    /// True while the manifest behind a deep link is being fetched for the
    /// prompt — keeps a second link from queueing a second dialog.
    @State private var addonInstallInFlight = false

    struct PendingAddonInstall: Identifiable {
        let id = UUID()
        let manifestURL: String
        let name: String
        /// Already installed: the prompt says "Update" instead of "Install".
        let isUpdate: Bool
    }

    @State private var sync: NuvioSyncManager?
    /// Held only by -addonServerProbe; nil in normal runs.
    @State private var devAddonServer: AddonImportServer?
    @State private var showProfileGate = false
    /// First launch, nobody signed in — the welcome screen sits in front of
    /// everything, including the profile gate.
    @State private var showWelcome = false
    /// True when the gate was opened from the rail / Settings (Back closes
    /// it); false for the cold-launch gate, where Back stays a no-op.
    @State private var profileGateCancellable = false
    @State private var selectedTab = 0
    /// Polls the account every 30s while Home is up so Continue Watching stays
    /// live — removals and additions made on another device (or that failed to
    /// reconcile on foreground) appear without a relaunch. Fires continuously;
    /// the receiver gates it to Home + active + not-in-player. A no-change pull
    /// mutates nothing (mergeRemote only publishes on a real diff), so an idle
    /// Home doesn't re-render.
    /// `.default`, NOT `.common`: common-mode timers fire inside the run-loop
    /// tracking mode focus/scroll animations run in, waking SwiftUI mid-scroll
    /// for a poll that is never urgent. Tier-scaled: on the A8/A10X the full
    /// account sync already runs every 90s, and a second independent 30s pull
    /// over the same data doubled the recurring decode/merge load for nothing.
    private let continueWatchingPoll = Timer.publish(
        every: (PerformanceProfile.isLowPower || PerformanceProfile.isMidPower) ? 60 : 30,
        on: .main, in: .default
    ).autoconnect()
    /// When Home last popped back from a pushed screen — used to swallow the
    /// stray Menu that otherwise opens the sidebar right after backing out.
    @State private var lastHomePopAt: Date?
    @FocusState private var sidebarFocus: Int?
    /// The rail is briefly non-focusable at launch so initial focus lands in
    /// the CONTENT (the app boots with the rail collapsed and a card focused).
    @State private var sidebarEnabled = false
    /// Settings lists lock the top bar out while an entry is moved.
    @ObservedObject private var topBarLock = TopBarLock.shared

    @ObservedObject private var launch = LaunchPreloader.shared

    var body: some View {
        content
            // While the source picker (or a search) is up, nothing under it
            // takes focus — nor under the launch screen.
            .disabled(sourcePicker.request != nil || launcher.search?.overlay == true || launch.curtain)
            // THE LAUNCH (docs/LOADING-PLAN.md §4): over everything on a cold
            // start while the closest things get ready; Home is built under
            // it.
            .overlay { LaunchCurtain() }
            .animation(.easeOut(duration: 0.35), value: launch.curtain)
            .task { launch.run(home: homeViewModel, addonManager: addonManager) }
            // The welcome screen or the profile gate up: they cover it — no
            // curtain on top (the preload carries on behind).
            .onChange(of: showWelcome) { _, on in if on { launch.skip() } }
            .onChange(of: showProfileGate) { _, on in if on { launch.skip() } }
            // Play from a card or an episode: finding its source, over the
            // app (Back cancels — see `PlayLauncher`).
            .overlay {
                if let search = launcher.search, search.overlay {
                    ZStack {
                        Color.black.opacity(0.45).ignoresSafeArea()
                        FindingSourceCard(search: search) { launcher.cancel() }
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: launcher.search?.overlay == true)
            // The source picker, over everything (`SourcePicker`): pops in
            // like a menu over the app; plays what's picked.
            .overlay {
                if let request = sourcePicker.request {
                    ZStack {
                        // (No dimming behind it — the panel's glass is enough.)
                        SourcePanel(meta: request.meta, video: request.video, onPlay: { entry, all in
                            sourcePicker.close()
                            play(request.meta, request.video, entry, all, fromStart: request.fromStart)
                        }, onClose: { sourcePicker.close() })
                        .id(request.id)
                        .ignoresSafeArea()
                        .transition(.scale(scale: 0.96, anchor: .trailing).combined(with: .opacity))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: sourcePicker.request?.id)
            .onOpenURL { handleDeepLink($0) }
            .onChange(of: sidebarFocus) { old, new in traceSidebar(old, new) }
            .onChange(of: sidebarEnabled) { _, new in traceSidebarEnabled(new) }
            // Install the hold trace when the setting is switched ON, not only
            // in onAppear: turning "Hold menu probe" on mid-session used to
            // bring up the HUD with nothing to report until the next relaunch.
            // `install()` is idempotent, so a second call is free.
            .onChange(of: perf.settings.showHoldProbe) { _, on in
                // Off matters as much as on: the trace installs a focus-change
                // observer that walks ten superviews and logs on EVERY focus
                // move, plus a window-wide long-press recogniser. Left behind,
                // they cost that on the A8/A10X boxes for the rest of the
                // session after the user switched the probe back off.
                if on { HoldInteractionTrace.install() }
                else { HoldInteractionTrace.uninstall() }
            }
            .onAppear {
                NSLog("[CuePlayer] RootView content onAppear")
                FocusTrace.installIfRequested()
                if perf.settings.showHoldProbe { HoldInteractionTrace.install() }
                startPlayerDemoIfRequested()
                startDetailDemoIfRequested()
                ScrubThumbnailer.runSelfTestIfRequested()
                PlayLauncher.shared.configure(.init(
                    addonManager: addonManager, progress: progressStore, watched: watched,
                    settings: { [playerSettings] in playerSettings.settings },
                    start: { meta, video, entry, all, fromStart in
                        play(meta, video, entry, all, fromStart: fromStart)
                    }))
                TitleMenu.shared.configure(library: library, watched: watched, progress: progressStore,
                                           addonManager: addonManager)
            }
            .task {
                if sync == nil {
                    // Finishing a title records it in watched history.
                    progressStore.onFinished = { [weak watched] meta, video in
                        watched?.mark(meta: meta, video: video, fromPlayback: true)
                    }
                    // A synced row for an episode finished AFTER that row was
                    // written is a stale copy; no merge may restore it (see
                    // `ProgressStore.episodeWatchedAfter`).
                    progressStore.episodeWatchedAfter = { [weak watched] row in
                        guard let watched, let season = row.season, let episode = row.episode,
                              let mark = watched.items[WatchedItem.key(contentID: row.metaID,
                                                                       season: season,
                                                                       episode: episode)]
                        else { return false }
                        return mark.watchedAt > row.updatedAt
                    }
                    let nuvioSync = NuvioSyncManager(
                        account: account,
                        addonManager: addonManager,
                        progressStore: progressStore,
                        libraryStore: library,
                        watchedStore: watched,
                        profileStore: profiles,
                        collectionsStore: collections,
                        homeCatalogSettings: homeCatalogSettings,
                        streamBadges: streamBadges,
                        playerSettings: playerSettings,
                        tmdbSettings: tmdbSettings,
                        themeManager: theme
                    )
                    sync = nuvioSync
                    // Everything personal rescopes on a switch, even when
                    // signed out of Cue (the sync manager only runs while
                    // signed in): add-ons (honouring the
                    // profile's use-primary fallbacks), player
                    // settings, TMDB, theme, badges — upstream Nuvio's
                    // per-profile boundary, ported wholesale.
                    profiles.onSwitchLocal = { [weak addonManager,
                                                weak playerSettings,
                                                weak tmdbSettings, weak streamBadges,
                                                weak profiles] id in
                        let flags = profiles?.profiles.first { $0.id == id }
                        addonManager?.setProfile(flags?.usesPrimaryAddons == true ? 1 : id)
                        playerSettings?.setProfile(id)
                        tmdbSettings?.setProfile(id)
                        streamBadges?.setProfile(id)
                        // Every store just re-pointed at another profile's
                        // data; reconcile the new picture everywhere rather
                        // than waiting for a tick.
                        SyncCoordinator.shared.requestFullSync("profile switched")
                    }
                    profiles.onProfileLockChanged = { [weak progressStore] in
                        progressStore?.refreshTopShelf()
                    }
                    // Write the shelf once at launch. Every other trigger is a
                    // CHANGE — a progress save, a PIN flip — so a device whose
                    // Continue Watching arrived from the account (a reinstall,
                    // a second box) had nothing on the tvOS home screen until
                    // it played something. Also logs where the snapshot went,
                    // which is the only way to tell "no rows" apart from "the
                    // signer stripped the app group" from a device log.
                    progressStore.refreshTopShelf()
                    NSLog("[TopShelf] app group %@ → %@", AppGroupResolver.identifier,
                          AppGroupResolver.sharedFile("topshelf.json")?.path ?? "UNAVAILABLE")
                    profiles.onProfileDeleted = { [weak addonManager,
                                                   weak playerSettings,
                                                   weak tmdbSettings, weak streamBadges,
                                                   weak nuvioSync] id in
                        addonManager?.forgetProfile(id)
                        playerSettings?.forgetProfile(id)
                        tmdbSettings?.forgetProfile(id)
                        streamBadges?.forgetProfile(id)
                        nuvioSync?.syncProfilesNow()
                        SyncCoordinator.shared.requestFullSync("profile deleted")
                    }
                    // Anything sync-relevant that happens locally now kicks a
                    // full sync of every destination, debounced (see
                    // SyncCoordinator). Registered by name, so this is safe to
                    // reach twice.
                    // Coming back from Picture in Picture: re-present the
                    // cover for the session PiPHandoff kept alive.
                    PiPHandoff.shared.present = { request in
                        playback = request
                    }
                    let coordinator = SyncCoordinator.shared
                    coordinator.observe(watched: watched, library: library,
                                        progress: progressStore)
                    coordinator.addDestination("Nuvio") { [weak nuvioSync] in
                        Task { @MainActor in
                            // A change made from inside the player (mark
                            // watched, remove from Continue Watching) still
                            // reaches the account at once — through the light
                            // pass, so it cannot contend with the stream.
                            if NuvioSyncManager.playbackActive {
                                await nuvioSync?.syncLight(reason: "local change during playback")
                            } else {
                                await nuvioSync?.syncNow()
                            }
                        }
                    }
                    // Fix up any already-installed Community Collections after
                    // launch has yielded. Keep network-backed logo migration
                    // out of app-open startup; that runs when the collection
                    // screen is opened.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        CommunityCollections.runLaunchMigrations(collections: collections)
                    }
                    // "Who's watching?" gate on cold launch when 2+ profiles —
                    // OR whenever the profile about to become active is PIN
                    // locked. With only the count test, a device with a single
                    // PIN-locked profile booted straight into it and the lock
                    // the user had enabled protected nothing.
                    // Everything the browse probe needs that lives in a store
                    // rather than in this view. Weak, so a block registered
                    // here can never be what keeps a store alive, and
                    // re-registered harmlessly if the root ever reappears
                    // (`register` replaces by name).
                    installStoreProbe()
                    AppProbe.tab = Self.tabName(selectedTab)
                    AppProbe.life("root appeared — tab=\(Self.tabName(selectedTab))")
                    // Skipped in the demo modes so the screen isn't covered.
                    let args = ProcessInfo.processInfo.arguments
                    let demoArgs = ["-detailDemo", "-detailDemoSeries", "-homeDemo", "-settingsDemo","-searchDemo", "-libraryDemo", "-discoverDemo", "-accountDemo", "-settingsTabDemo", "-settingsPage"]
                    let demoMode = demoArgs.contains { args.contains($0) }
                    // -welcomeDemo forces it regardless of the completed flag
                    // or an already-restored session, which is the only way to
                    // look at this screen twice on one install.
                    let forceWelcome = args.contains("-welcomeDemo")
                        || args.contains("-welcomeOfferDemo")
                    showWelcome = (forceWelcome || OnboardingState.shouldShow(
                        signedIn: account.authState.isSignedIn)) && !demoMode
                    showProfileGate = (profiles.profiles.count >= 2 || profiles.active.pinEnabled) && !demoMode
                    if args.contains("-settingsDemo") { selectedTab = 3 }
                    // Settings TAB (in-place, not the full-screen pane demo) —
                    // used to drive the ATV theme's settings in the sim.
                    if args.contains("-settingsTabDemo") { selectedTab = 3 }
                    // A Settings page, opened the real way (Back returns to
                    // Settings): -accountDemo, or -settingsPage <category>.
                    if args.contains("-accountDemo") {
                        selectedTab = 3
                        settingsPath.append(SettingsCategory.account)
                    }
                    if let flag = args.firstIndex(of: "-settingsPage"), flag + 1 < args.count,
                       let category = SettingsCategory(rawValue: args[flag + 1]) {
                        selectedTab = 3
                        settingsPath.append(category)
                    }
                    if args.contains("-searchDemo") { selectedTab = 1 }
                    if args.contains("-libraryDemo") { selectedTab = 2 }
                    // A collection's folder, opened from Home (the simulator can't
                    // select): `-folderDemo <n>` — the n-th collection's first.
                    if let flag = args.firstIndex(of: "-folderDemo") {
                        let n = flag + 1 < args.count ? Int(args[flag + 1]) ?? 0 : 0
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            let shelves = collections.collections.filter { !$0.folders.isEmpty }
                            if shelves.indices.contains(n), let folder = shelves[n].folders.first {
                                homePath.append(Route.folder(shelves[n], folder))
                            }
                        }
                    }
                    // Dev: run the add-on import server standalone and log
                    // its address, so the HTTP path can be exercised without
                    // driving the settings UI.
                    if args.contains("-addonServerProbe") {
                        let server = AddonImportServer()
                        server.onInstall = { [weak addonManager] url in
                            guard let addonManager else { return .failure(URLError(.cancelled)) }
                            do {
                                try await addonManager.install(manifestURL: url)
                                let m = addonManager.addons.first { $0.manifestURL == url }?.manifest
                                return .success(.init(manifestURL: url, name: m?.name ?? url,
                                                      logo: m?.logo, description: m?.description))
                            } catch { return .failure(error) }
                        }
                        server.start()
                        devAddonServer = server
                        Task { @MainActor in
                            for _ in 0..<20 {
                                if let a = server.address {
                                    NSLog("[CueAddonServer] listening at %@", a); return
                                }
                                try? await Task.sleep(nanoseconds: 250_000_000)
                            }
                            NSLog("[CueAddonServer] never became ready: %@",
                                  server.lastError ?? "unknown")
                        }
                    }
                    // Dev: can this device do Picture in Picture at all?
                    if args.contains("-pipProbe") {
                        // Each probe run starts a fresh trail.
                        UserDefaults.standard.removeObject(forKey: "dev.pipTrail")
                        NSLog("[CuePiP] isPictureInPictureSupported=%d",
                              AVPictureInPictureController.isPictureInPictureSupported() ? 1 : 0)
                    }
                    // Dev: what search will query, in order, and what one real
                    // query returns from each — the ordering is the whole point
                    // of searchTargets and is otherwise invisible.
                    if args.contains("-searchProbe") {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            let targets = SearchViewModel.searchTargets(addonManager)
                            var lines: [String] = []
                            for (i, t) in targets.enumerated() {
                                let m = t.0.manifest
                                lines.append("\(i). \(m.name) [\(t.1.type)/\(t.1.id)]"
                                             + " meta=\(m.providesMeta) stream=\(m.providesStreams)")
                            }
                            // Write the ORDER first: the slow part below is a
                            // real query per catalog and must not be able to
                            // lose the answer we already have.
                            UserDefaults.standard.set(lines.joined(separator: "\n"),
                                                      forKey: "dev.searchProbe")
                            NSLog("[CueSearch] order written (%d targets)", targets.count)
                            await withTaskGroup(of: (Int, [MetaItem]).self) { group in
                                for (i, t) in targets.enumerated() {
                                    group.addTask {
                                        ((i, (try? await StremioAPI.catalog(
                                            addon: t.0, catalog: t.1, search: "breaking bad")) ?? []))
                                    }
                                }
                                var got: [Int: [MetaItem]] = [:]
                                for await (i, items) in group { got[i] = items }
                                for i in targets.indices {
                                    let items = got[i] ?? []
                                    lines.append("RESULT \(i) \(targets[i].0.manifest.name): \(items.count) — "
                                                 + items.prefix(3).map(\.name).joined(separator: " | "))
                                }
                            }
                            UserDefaults.standard.set(lines.joined(separator: "\n"),
                                                      forKey: "dev.searchProbe")
                            NSLog("[CueSearch] probe written")
                        }
                    }
                    // Dev: remove a title from Continue Watching through the
                    // same call the hold menu makes, so the fan-out to Cue
                    // can be exercised without the tvOS UI.
                    if let meta = args.first(where: { $0.hasPrefix("-removeCW:") })?
                        .replacingOccurrences(of: "-removeCW:", with: ""), !meta.isEmpty {
                        progressStore.removeShow(metaID: meta, notifySync: true)
                    }
                    // Dev: switch profile, the same call the profile gate makes.
                    if let p = args.first(where: { $0.hasPrefix("-profile:") })?
                        .replacingOccurrences(of: "-profile:", with: ""), let id = Int(p) {
                        profiles.setActive(id)
                    }
                    // Dev: expand the rail shortly after launch (sim key
                    // delivery is flaky; this makes the expanded panel
                    // screenshot-able without remote input).
                    if args.contains("-railDemo") {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            sidebarEnabled = true
                            sidebarFocus = 0
                        }
                    }
                    // Dev: jump straight to the profile gate.
                    // As opened from the top bar's avatar (with Edit).
                    if args.contains("-profileGateDemo") {
                        profileGateCancellable = true
                        showProfileGate = true
                    }
                    // Dev/recovery: run the account-wide watch-history clear on
                    // launch (same code path as the Settings button) — lets a
                    // flooded device be repaired over devicectl without driving
                    // the tvOS UI. Waits for sign-in state to settle first.
                    // Dev/recovery: import Continue Watching rows from
                    // Documents/cue-progress-restore.json (an array of
                    // WatchProgress, e.g. lifted from a device backup) and push
                    // them to the account. Each row is re-stamped to NOW, both
                    // so it wins over anything stale and so it sits after the
                    // watch-history clear horizon instead of being filtered out
                    // by it on the next pull.
                    if args.contains("-restoreProgress") {
                        Task { @MainActor [weak nuvioSync] in
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            let url = FileManager.default
                                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("cue-progress-restore.json")
                            guard let data = try? Data(contentsOf: url),
                                  let rows = try? JSONDecoder().decode([WatchProgress].self, from: data)
                            else {
                                NSLog("[NuvioSync] -restoreProgress: no readable payload at %@", url.path)
                                return
                            }
                            let stamped = rows.map { row -> WatchProgress in
                                var copy = row
                                copy.updatedAt = Date()
                                return copy
                            }
                            progressStore.importEntries(stamped)
                            await nuvioSync?.pushThisDevice()
                            NSLog("[NuvioSync] -restoreProgress: imported %d rows", stamped.count)
                        }
                    }
                    if args.contains("-clearWatchHistory") {
                        Task { @MainActor [weak nuvioSync] in
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            await nuvioSync?.clearWatchHistoryEverywhere()
                            NSLog("[NuvioSync] -clearWatchHistory launch action finished")
                        }
                    }
                }
            }
            // Presented AFTER the profile gate's modifier so it layers on
            // top: on a fresh install both would otherwise want the screen,
            // and "who's watching" makes no sense before "who are you".
            .fullScreenCover(isPresented: $showWelcome) {
                WelcomeView(account: account, addonManager: addonManager) {
                    OnboardingState.completed = true
                    showWelcome = false
                }
                .environmentObject(theme)
            }
            .fullScreenCover(isPresented: $showProfileGate) {
                // Choosing a profile — and, opened from the top bar's avatar,
                // editing them (its Edit tile). The Nuvio account lives in
                // Settings → Account.
                ProfileGateView(
                    onSelected: { showProfileGate = false; deferSidebarAfterProfileGate() },
                    onCancel: profileGateCancellable
                        ? { showProfileGate = false; deferSidebarAfterProfileGate() }
                        : nil
                )
                .environmentObject(theme)
                .environmentObject(profiles)
                .environmentObject(account)
                .environmentObject(addonManager)
            }
            // Returning to the app pulls the latest Continue Watching so changes
            // made on another device show up without a relaunch (local edits
            // already push immediately on every change).
            .onChange(of: scenePhase) { _, phase in
                AppProbe.scene = "\(phase)"
                AppProbe.life("scene → \(phase)")
                if phase == .active {
                    // Opening the app syncs the whole account, not just
                    // Continue Watching — add-ons, collections, the layout and
                    // the player/theme settings all change on other devices
                    // too, and waiting for the periodic tick (30s, 90s on the
                    // A8/A10X) meant the app opened showing yesterday's copy.
                    // Self-coalescing and self-throttled: a cold launch arms
                    // this from the auth change as well, a quick
                    // inactive→active flip is ignored, and a cycle already
                    // running is reused rather than duplicated.
                    sync?.syncOnAppOpen(reason: "app opened")
                    // Stands down on its own while that sync is armed, so the
                    // two can't pull progress and library at the same time.
                    sync?.refreshContinueWatching()
                    // An add-on left as a stub — its manifest fetch answered
                    // during a wake, before the network was really back — has
                    // no catalogs and serves no streams, and NOTHING else
                    // re-fetches manifests until the next launch. That is why a
                    // missing add-on came back only after closing the app.
                    // Same repair the Sources screen already runs, and it does
                    // nothing when there is no stub to fix.
                    if addonManager.addons.contains(where: { $0.enabled && $0.manifest.isPlaceholder }) {
                        Task { _ = await addonManager.resolvePlaceholders() }
                    }
                }
            }
            // Keep Continue Watching live while browsing Home (tab 0), app
            // active, no player open. refreshContinueWatching pulls a full
            // snapshot; mergeRemote reconciles both adds and removes.
            .onReceive(continueWatchingPoll) { _ in
                guard scenePhase == .active, selectedTab == 0, playback == nil else { return }
                sync?.refreshContinueWatching()
            }
    }

    private func traceSidebar(_ old: Int?, _ new: Int?) {
        #if DEBUG
        guard FocusTrace.enabled else { return }
        NSLog("[FocusTrace] sidebarFocus %@ -> %@ (enabled=%d)",
              old.map(String.init) ?? "nil", new.map(String.init) ?? "nil", sidebarEnabled ? 1 : 0)
        #endif
    }

    private func traceSidebarEnabled(_ enabled: Bool) {
        #if DEBUG
        guard FocusTrace.enabled else { return }
        NSLog("[FocusTrace] sidebarEnabled=%d", enabled ? 1 : 0)
        #endif
    }

    private static var playerDemoStarted = false

    /// Dev-only: `-playerDemo` opens the player with Apple's public HLS test
    /// stream (`-playerDemoMKV` uses an MKV sample to exercise the FFmpeg
    /// engine) so playback UI can be verified without a stream addon.
    private func startPlayerDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let wantsMKV = args.contains("-playerDemoMKV")
        guard wantsMKV || args.contains("-playerDemo") else { return }
        // Once per process: the root content re-appears whenever the player
        // cover dismisses — including the Picture in Picture handoff — and a
        // second demo session would tear the parked one down.
        guard !Self.playerDemoStarted else { return }
        Self.playerDemoStarted = true
        let meta = MetaItem(
            id: "tt0111161", type: "movie", name: wantsMKV ? "Demo Stream (MKV)" : "Demo Stream (HLS)"
        )
        let stream = Stream(
            name: wantsMKV ? "MKV Sample\n1080p" : "Apple HLS\n1080p",
            title: wantsMKV ? "Big Buck Bunny MKV sample" : "BipBop advanced fMP4 example",
            description: nil,
            url: wantsMKV
                ? "https://test-videos.co.uk/vids/bigbuckbunny/mkv/1080/Big_Buck_Bunny_1080_10s_5MB.mkv"
                : "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
            infoHash: nil, behaviorHints: nil
        )
        playback = PlaybackRequest(
            meta: meta, video: nil,
            entry: StreamEntry(addonName: "Demo", stream: stream),
            allEntries: [], resumePosition: nil
        )
    }

    /// Dev-only: `-detailDemo` jumps straight to a Detail screen for a known
    /// title so TMDB/Trakt enrichment (cast, trailers, more-like-this, comments)
    /// can be verified without navigating there by remote.
    private func startDetailDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        // `-detailDemoSeries` opens a known series so the episode browser +
        // Episode Details drawer can be screenshot-verified.
        // (An IMDb id after it opens that series instead.)
        if let at = args.firstIndex(of: "-detailDemoSeries") {
            let id = args.indices.contains(at + 1) && args[at + 1].hasPrefix("tt") ? args[at + 1] : "tt0903747"
            let meta = MetaItem(id: id, type: "series", name: id == "tt0903747" ? "Breaking Bad" : "")
            if homePath.isEmpty { homePath.append(Route.detail(meta)) }
            return
        }
        guard args.contains("-detailDemo") else { return }
        let meta = MetaItem(id: "tt0111161", type: "movie", name: "The Shawshank Redemption")
        if homePath.isEmpty { homePath.append(Route.detail(meta)) }
    }

    private var content: some View {
        // Dev-only: open a detail page directly, so the page's opening focus
        // and the hold-Select menu on Play can be driven from a UI test
        // without navigating through Home. `-detailSeries` renders a show
        // instead of a movie — the two branches of the action row are the
        // working/broken pair for the hold menu.
        if ProcessInfo.processInfo.arguments.contains("-detailDemo") {
            let args = ProcessInfo.processInfo.arguments
            let series = args.contains("-detailSeries")
            // `-detailID tt…`: that series instead (e.g. a long one to profile).
            let picked = args.firstIndex(of: "-detailID").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            if let picked {
                return AnyView(ZStack {
                    theme.palette.background.ignoresSafeArea()
                    DetailView(item: MetaItem(id: picked, type: "series", name: picked))
                })
            }
            return AnyView(
                ZStack {
                    theme.palette.background.ignoresSafeArea()
                    DetailView(
                        item: series
                            ? MetaItem(id: "tt0903747", type: "series", name: "Breaking Bad",
                                       description: "A chemistry teacher turns to making meth.")
                            : MetaItem(id: "tt0111161", type: "movie", name: "The Shawshank Redemption",
                                       description: "Two imprisoned men bond over a number of years.")
                    )
                }
            )
        }
        return AnyView(mainContent)
    }

    private var mainContent: some View {
        tabLayout
        // Developer FPS read-out over the whole UI (Settings → Performance).
        .overlay {
            if perf.settings.showFPSOverlay { FPSOverlay() }
            if perf.settings.showHoldProbe { HoldProbeHUD() }
        }
        // App-wide toast (Fusion): Added to Library / Marked Watched / etc.
        .overlay { FusionToastHost() }
        .fullScreenCover(item: $playback, onDismiss: {
            // Pop the auto-played source page ONLY after the cover has fully
            // torn down. Mutating the NavigationStack path in the same runloop
            // tick that dismisses the cover desyncs the stack — the path empties
            // but the pushed source view lingers as a focused "ghost" (looks
            // glitched; Back on it escapes to tvOS and quits the app). The extra
            // TabView layer in the Fusion layout makes that race fire reliably.
            // Deferring to onDismiss + the next tick sequences the two mutations.
            guard pendingAutoPlayPop else { return }
            pendingAutoPlayPop = false
            DispatchQueue.main.async { popActivePathForAutoPlay() }
        }) { request in
            PlayerScreen(
                request: request,
                addonManager: addonManager,
                progressStore: progressStore,
                playerSettings: playerSettings.settings
            ) {
                // Just dismiss the cover; the auto-play pop runs in onDismiss.
                playback = nil
            }
        }
        // Deep-link add-on install confirmation. A tvOS alert is fully
        // focusable and remote-navigable, and Cancel carries the `.cancel`
        // role so a Menu press is a REFUSAL — the safe default for a prompt
        // the viewer may not have asked for.
        .alert(
            pendingAddonInstall?.isUpdate == true ? "Update add-on?" : "Install add-on?",
            isPresented: Binding(
                get: { pendingAddonInstall != nil },
                set: { if !$0 { pendingAddonInstall = nil } }
            ),
            presenting: pendingAddonInstall
        ) { pending in
            Button(pending.isUpdate ? "Update" : "Install") { confirmAddonInstall(pending) }
            Button("Cancel", role: .cancel) { pendingAddonInstall = nil }
        } message: { pending in
            Text("\(pending.name)\n\(pending.manifestURL)\n\nThis add-on will be able to supply catalogs, metadata and stream links to Cue.")
        }
    }

    /// Whether the current tab is at its root (no pushed screen). When a
    /// Detail/Streams/etc. is pushed the rail hides so that screen runs
    /// full-bleed.
    private var atTabRoot: Bool {
        switch selectedTab {
        case 0: return homePath.isEmpty
        case 1: return searchPath.isEmpty
        case 2: return libraryPath.isEmpty
        case 4: return moviesPath.isEmpty
        case 5: return seriesPath.isEmpty
        default: return true   // Settings keeps the rail
        }
    }

    /// Layout → "Hide the sidebar until it's needed": the collapsed rail is
    /// off screen entirely and content runs full width, until a sideways press
    /// at the left edge of the content (or Menu) calls it back. Settings keeps
    /// its rail regardless — that pane is navigated THROUGH the rail, and
    /// hiding it there leaves no way back out of a settings detail.
    private var sidebarAutoHides: Bool {
        homeCatalogSettings.autoHideSidebar && selectedTab != 3
    }

    /// Set when the auto-hiding rail has been summoned; cleared when it
    /// collapses again.
    @State private var sidebarRevealed = false

    /// When the rail was last ASKED for — a summon, or focus actually landing
    /// in it. Read only by the rail's exit-move handler; see the note there.
    @State private var sidebarEngagedAt = Date.distantPast

    /// How long after engaging the rail an exit move is treated as an echo of
    /// the gesture that opened it rather than a fresh instruction to leave.
    ///
    /// Short enough that a deliberate press pair is never swallowed (two
    /// separate presses on the clickpad are far slower than this), long enough
    /// to cover the tail of ONE swipe on the old remote's touch surface.
    private static let sidebarExitEchoWindow: TimeInterval = 0.3
    /// A Back right after a pop: tvOS sometimes delivers the pop's Back a
    /// second time, within a frame or two — a real second press comes later.
    private static let popEchoWindow: TimeInterval = 0.25
    /// The top bar non-focusable for a moment, so the engine seeds focus in
    /// the content (after a tab switch, leaving the bar, a pop): as short as
    /// focus needs to settle — every Up in it is lost.
    private static let railSettle: Double = 0.25

    /// The top bar is out for the billboard's trailer — Home's tab only
    /// (another tab's bar is never part of it).
    private var homeChromeOut: Bool {
        modeSwap.trailerChromeOut && onHomeLikeTab
    }

    private var showSidebar: Bool {
        guard atTabRoot else { return false }
        return !sidebarAutoHides || sidebarRevealed
    }

    /// Bring a hidden rail back and put focus on it. The reveal has to happen
    /// BEFORE the focus write — the rail isn't in the view tree until
    /// `showSidebar` turns true, and `@FocusState` on a view that doesn't
    /// exist yet is dropped on the floor.
    private func revealSidebar() {
        guard sidebarAutoHides, !sidebarRevealed else {
            AppProbe.focus("reveal rail refused — autoHides=\(sidebarAutoHides.probe)"
                           + " alreadyRevealed=\(sidebarRevealed.probe)")
            return
        }
        // The failed-move notification is app-wide: a left press with no
        // target inside the player, a pushed Detail page, or either fullscreen
        // gate reaches here too, and revealing there would flip state for a
        // rail that isn't even on screen — it then greets the viewer already
        // open when they come back to the root.
        guard atTabRoot, playback == nil, !showProfileGate, !showWelcome else {
            AppProbe.focus("reveal rail refused — atRoot=\(atTabRoot.probe)"
                           + " player=\((playback != nil).probe) gate=\(showProfileGate.probe)"
                           + " welcome=\(showWelcome.probe)")
            return
        }
        AppProbe.focus("reveal rail")
        sidebarRevealed = true
        sidebarEngagedAt = Date()
        setSidebarEnabled(true)
        DispatchQueue.main.async { sidebarFocus = selectedTab }
    }

    /// The app's single root: the top navigation floating over full-bleed
    /// content. OVERLAY layout, so the bar just draws over the content.
    private var tabLayout: some View {
        ZStack(alignment: .top) {
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Tab changes CUT. No fade, in either direction.
                //
                // There were two attempts at fading before this, and each one
                // exposed something it shouldn't:
                //
                // 1. `insertion: .opacity, removal: .identity`. `.identity`
                //    does not mean "leaves the tree at once" — it means no
                //    visual transform is applied, so the outgoing page stayed
                //    FULLY OPAQUE for the whole 0.22s while the new one faded
                //    in on top of it. Home's hero art showed straight through
                //    the half-faded page arriving over it.
                // 2. Removing the outgoing page over ~0 seconds fixed that,
                //    and then the fade-in had nothing in front of the app
                //    background — so `ATVBackground`'s accent bloom flashed
                //    through the half-transparent page instead.
                //
                // Both are the same root cause: a page that is partially
                // transparent shows whatever is behind it, and on this screen
                // there is always something behind it worth not seeing. A cut
                // has no transparent frame at all, which is also what the
                // system tvOS apps do when moving between tabs.
                //
                // (No `.id(selectedTab)` any more: it tore each tab down and
                // rebuilt it on every switch — below 10 fps, and every page
                // started over. Tabs now stay alive; see `selectedContent`.)
                .animation(nil, value: selectedTab)
                .focusSection()
                // Summon a hidden bar — but ONLY from the top edge. A
                // section's move handler fires on EVERY press anywhere in the
                // content; `movementDidFailNotification` is the engine's own
                // "I looked and found nothing" — exactly the press from the
                // top row, and nothing else.
                .onReceive(NotificationCenter.default.publisher(
                    for: UIFocusSystem.movementDidFailNotification)) { note in
                    guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                            as? UIFocusUpdateContext else { return }
                    // The press that reaches for the bar: Up.
                    guard ctx.focusHeading.contains(.up) else { return }
                    // Search root with the rail ON SCREEN but inside one of its
                    // short `.disabled` windows (the moments after a tab switch
                    // or a rail exit, kept so the engine seeds focus into the
                    // content). A disabled rail can't take focus, so this Left
                    // failed and was swallowed: the search bar read as a trap
                    // while Back, which force-enables the rail, still worked.
                    // A deliberate Left now takes Back's path. Search only.
                    if selectedTab == 1, showSidebar, !sidebarEnabled, sidebarFocus == nil,
                       playback == nil, !showProfileGate, !showWelcome {
                        focusSidebar(selectedTab)
                    } else if showSidebar, sidebarFocus == nil, atTabRoot,
                              playback == nil, !showProfileGate, !showWelcome {
                        // TOP BAR, already on screen, and Up found nothing: put
                        // focus in it.
                        //
                        // The bar sits OVER content that
                        // spans the full height, and from a page whose own
                        // topmost row is close under it the engine answers "no
                        // candidate" instead of stepping up into it. The press
                        // then did nothing at all: Library's filter chips were
                        // a dead end upward, and with "Hide the sidebar" on
                        // there was no way to call the bar back either, because
                        // the branch below only reveals a bar that is OFF
                        // screen. Same remedy the Search case above uses, which
                        // is the same problem on the other axis.
                        focusSidebar(selectedTab)
                    } else {
                        revealSidebar()
                    }
                }

            if showSidebar {
                GlassSidebar(selected: $selectedTab, focusBinding: $sidebarFocus,
                             onProfileTap: { profileGateCancellable = true; showProfileGate = true },
                             onTabSelected: { newTab in selectTab(newTab) },
                             // The billboard ⇄ Details swap: the bar moves
                             // away (up) — inside the bar, on its items (see
                             // `GlassSidebar.swapAway`).
                             swapAway: homeChromeOut)
                    .opacity(homeChromeOut ? 0 : 1)
                    .animation(ModeSwap.swap, value: homeChromeOut)
                    .focusSection()
                    .disabled(!sidebarEnabled || homeChromeOut || !atTabRoot || topBarLock.locked)
                    // Back while IN the rail collapses it into content instead
                    // of falling through to the system (which quit the app).
                    .onExitCommand { collapseSidebarFromExit() }
                    // Swipe/press RIGHT exits into content: the content's focus
                    // section is UNDER the panel (overlapping, not beside it),
                    // so the engine sees no candidate to the right — catch it
                    // and run the same collapse Back uses.
                    .onMoveCommand { direction in
                        // Out of the bar and into the content: Down.
                        guard direction == .down else { return }
                        // …unless this is the tail of the swipe that just
                        // OPENED the rail.
                        //
                        // The old Siri Remote's touch surface reports a swipe
                        // as a stream of move commands, and the settling end of
                        // one carries a move back the other way; the clickpad
                        // on the current remote emits a single discrete press
                        // and never does this. So a swipe left landed focus in
                        // the rail and the same gesture's tail immediately
                        // exited it — the panel opened and bounced straight
                        // back, only ever on the old remote. The race below
                        // makes it worse: this block is async, so a tail that
                        // arrives before focus has settled sees `sidebarFocus`
                        // still nil and disables the rail exactly as focus is
                        // arriving, which pushes it back to the content too.
                        //
                        // A leaving move is only real once the opening one has
                        // had time to finish.
                        guard Date().timeIntervalSince(sidebarEngagedAt)
                                > Self.sidebarExitEchoWindow else { return }
                        // The engine acts on this press too: on tabs whose
                        // content clears only the COLLAPSED rail, cards past
                        // the panel's edge are real right candidates, so focus
                        // may already have moved by the next tick. Then the
                        // engine's pick stands — only the housekeeping runs —
                        // instead of a second, visible teleport on top of it.
                        DispatchQueue.main.async {
                            if sidebarFocus != nil {
                                collapseSidebarFromExit()
                            } else {
                                if sidebarAutoHides { sidebarRevealed = false }
                                setSidebarEnabled(false, reenableAfter: Self.railSettle)
                            }
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // Stays non-focusable until Home has content to hold
                    // initial focus (onContentReady); timer is the fallback.
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        // Cold-launch fallback ONLY. When a tab switch is
                        // deliberately waiting on onContentReady, this timer
                        // used to flip the rail focusable over slow addons
                        // and the panel reclaimed initial focus.
                        if sidebarReenableTask == nil, !sidebarAwaitingContent {
                            sidebarEnabled = true
                        }
                    }
            }
        }
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: showSidebar)
        .animation(perf.sidebarAnimationEffective
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: sidebarFocus != nil)
        // Focus ARRIVING in the rail counts as engaging it, however it got
        // there. `focusSidebar` and `revealSidebar` stamp their own way in, but
        // the common case — an always-visible rail that the focus engine simply
        // moves into from the first card of a row — goes through neither, and
        // that is exactly the case a swipe hits.
        .onChange(of: sidebarFocus) { old, new in
            if old == nil, new != nil { sidebarEngagedAt = Date() }
        }
        .background(ATVBackground())
    }

    /// The screen for the selected rail tab, each in its own NavigationStack
    /// so per-tab back-stacks stay independent. Back at a tab ROOT moves focus
    /// to the rail (expanding it); pushed screens hold focus themselves, so
    /// their Back pops the NavigationStack instead.
    private var selectedContent: some View {
        ZStack {
            // EVERY tab stays ALIVE once opened: switching only shows another
            // — instant, and each keeps its place (row, title, a pushed
            // Details, the search typed). Rebuilding the page on every switch
            // dropped below 10 fps.
            ForEach(AppTab.allCases.filter {
                visitedTabs.contains($0.rawValue) || selectedTab == $0.rawValue
            }) { tab in
                let active = selectedTab == tab.rawValue
                tabContent(tab, active: active)
                    // The bar FLOATS over Home (and Movies / Series), so the
                    // billboard is never pushed down. The other tabs get a
                    // SAFE-AREA inset rather than a plain one — see
                    // `topBarClearance`: plain padding cut the page off under
                    // the bar, so scrolled rows hit a black band instead of
                    // sliding under the glass.
                    .safeAreaPadding(.top, !tab.isHomeLike && tab != .search && (showSidebar || !active)
                                     ? GlassSidebar.topBarClearance : 0)
                    .opacity(active ? 1 : 0)
                    .disabled(!active)
                    .accessibilityHidden(!active)
                    .zIndex(active ? 1 : 0)
            }
        }
        .onChange(of: selectedTab) { _, tab in visitedTabs.insert(tab) }
    }

    /// Tabs opened so far (kept alive — see above).
    @State private var visitedTabs: Set<Int> = [AppTab.home.rawValue]

    @ViewBuilder
    private func tabContent(_ tab: AppTab, active: Bool) -> some View {
        switch tab {
        case .search:
            NavigationStack(path: $searchPath) {
                searchRoot(active: active)
                    .onExitCommand { focusSidebar(1) }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $searchPath) }
            }
            // Apple's search field and keyboard (UISearchController) ignore
            // the safe-area inset, and sat under the bar — a plain one here.
            // (The results scroll under the keyboard, never under the bar.)
            .padding(.top, searchPath.isEmpty ? GlassSidebar.topBarClearance : 0)
        case .library:
            NavigationStack(path: $libraryPath) {
                libraryRoot
                    .onExitCommand { focusSidebar(2) }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: $libraryPath) }
            }
        case .settings:
            NavigationStack(path: $settingsPath) {
                ATVSettingsView()
                    .onExitCommand { focusSidebar(3) }
                    .probeScreen("Settings")
            }
        case .movies:
            homeLikeStack(.movies, path: $moviesPath, active: active)
        case .series:
            homeLikeStack(.series, path: $seriesPath, active: active)
        case .home:
            homeLikeStack(.home, path: $homePath, active: active)
        }
    }

    /// Home, or its filtered twins Movies / Series: each in its own stack.
    private func homeLikeStack(_ tab: AppTab, path: Binding<NavigationPath>, active: Bool) -> some View {
        NavigationStack(path: path) {
            homeRoot(filter: tab.typeFilter, path: path, active: active)
                .onExitCommand {
                    // Handing over to Details: this Back is Details' (it
                    // takes the swap straight back).
                    if modeSwap.handingOver { modeSwap.heldPress = .back; return }
                    // Ignore a Menu that lands right after popping back from
                    // a pushed screen — tvOS sometimes delivers a lingering
                    // second Menu, which would spuriously open the rail.
                    if let popped = lastHomePopAt, Date().timeIntervalSince(popped) < Self.popEchoWindow { return }
                    focusSidebar(tab.rawValue)
                }
                .onChange(of: path.wrappedValue.count) { oldCount, newCount in
                    // Only a pop that lands ON the page matters here.
                    guard newCount < oldCount, newCount == 0 else { return }
                    lastHomePopAt = Date()
                    // Popping all the way back: keep the rail non-focusable
                    // for a beat so focus lands on a card instead of the rail
                    // springing open.
                    setSidebarEnabled(false, reenableAfter: Self.railSettle)
                }
                .navigationDestination(for: Route.self) { destination(for: $0, path: path) }
        }
    }

    /// Rail tabs by name, for the probe. Numbers in a log are a second thing
    /// to decode while reading a focus bug.
    static func tabName(_ tab: Int) -> String {
        switch tab {
        case 1: return "Search"
        case 2: return "Library"
        case 3: return "Settings"
        case 4: return "Movies"
        case 5: return "Series"
        default: return "Home"
        }
    }

    /// The `[stores]` probe block: what the app is holding right now, which is
    /// the other half of "why is this row empty" — the first half being the
    /// `data` events that tried to fill it.
    private func installStoreProbe() {
        PlayerProbe.register("stores") { [weak addonManager, weak collections,
                                          weak library, weak progressStore,
                                          weak profiles, weak account] in
            var out: [String] = []
            if let addonManager {
                let enabled = addonManager.addons.filter(\.enabled)
                let stubs = enabled.filter { $0.manifest.isPlaceholder }
                out.append("addons \(enabled.count)/\(addonManager.addons.count) enabled"
                           + (stubs.isEmpty ? "" : "  STUBS: " + stubs.map(\.manifest.name).joined(separator: ", ")))
            }
            if let collections {
                out.append("collections \(collections.library.count)")
            }
            if let library {
                out.append("library \(library.items.count)")
            }
            if let progressStore {
                out.append("continue watching \(progressStore.items.count)")
            }
            if let profiles {
                out.append("profile \(profiles.active.name) [\(profiles.active.id)]"
                           + "  of \(profiles.profiles.count)")
            }
            if let account {
                out.append("account \(account.authState.isSignedIn ? "signed in" : "signed out")")
            }
            return out
        }
    }

    /// Handles tapping a rail tab: collapse the panel and force focus into the
    /// fresh tab's content by making the rail momentarily unfocusable.
    private func selectTab(_ newTab: Int) {
        let enteringHomeFresh = selectedTab != 0 && newTab == 0
        AppProbe.nav("tab \(Self.tabName(selectedTab)) → \(Self.tabName(newTab))"
                     + (enteringHomeFresh ? "  (Home rebuilds; rail waits on content)" : ""))
        AppProbe.tab = Self.tabName(newTab)
        selectedTab = newTab
        if homeCatalogSettings.autoHideSidebar { sidebarRevealed = false }
        sidebarFocus = nil
        // Through the owner, so a pending re-enable (a rail exit moments ago)
        // is CANCELLED — it used to flip the rail focusable before the fresh
        // tab's content could hold focus, and the panel sprang open over it.
        setSidebarEnabled(false)
        // Entering Home fresh rebuilds HomeView; its onContentReady is the
        // sole re-enabler there (a blind timer could beat the rows to
        // focusability and the rail would reclaim focus).
        sidebarAwaitingContent = enteringHomeFresh
        guard enteringHomeFresh else {
            setSidebarEnabled(false, reenableAfter: Self.railSettle)
            return
        }
    }

    /// Open the rail on `tab`. The rail is `.disabled` for short windows after
    /// every tab switch / collapse / pop (so the engine seeds focus into the
    /// content instead), and a focus request into a disabled view is silently
    /// dropped — a Menu press in one of those windows did nothing. A deliberate
    /// Back always wins: enable now, focus on the next tick.
    private func focusSidebar(_ tab: Int) {
        AppProbe.focus("focusSidebar(\(Self.tabName(tab)))"
                       + "  revealed=\(sidebarRevealed.probe) enabled=\(sidebarEnabled.probe)")
        // Menu at a tab root is the other way back to a hidden rail.
        if sidebarAutoHides { sidebarRevealed = true }
        sidebarEngagedAt = Date()
        setSidebarEnabled(true)
        DispatchQueue.main.async { sidebarFocus = tab }
    }

    /// Back pressed while the rail itself is focused: close the panel. Always
    /// the fast fixed-delay re-enable — nothing is being freshly mounted.
    private func collapseSidebarFromExit() {
        // An auto-hiding rail goes all the way away again, not just narrow.
        if sidebarAutoHides { sidebarRevealed = false }
        // Hand focus to the FIRST tile of the row the viewer left, when that
        // row is mounted to take it. Dropping the rail's focus with no
        // destination let the engine pick whatever card sat nearest the
        // rail's centre — the fourth along, with the first two under the
        // panel. The rail stays enabled for the turn the hand-off needs; a
        // request into a `.disabled` view is silently dropped.
        if ContentFocusRouter.shared.focusLastRowStart() {
            DispatchQueue.main.async {
                sidebarFocus = nil   // a no-op once the tile holds focus
                setSidebarEnabled(false, reenableAfter: Self.railSettle)
            }
            return
        }
        sidebarFocus = nil
        setSidebarEnabled(false, reenableAfter: Self.railSettle)
    }

    /// The ONE owner of every timed rail re-enable. Five independent timers
    /// used to race each other: exit the rail (400ms re-enable pending), then
    /// switch tabs — the tab switch disabled the rail to keep initial focus in
    /// the content, and the stale 400ms timer flipped it back early, so the
    /// panel sprang open over the fresh screen. Scheduling through one task
    /// cancels whatever was pending first.
    @State private var sidebarReenableTask: Task<Void, Never>?

    private func setSidebarEnabled(_ enabled: Bool, reenableAfter delay: Double? = nil) {
        // The rail's `.disabled` windows swallow directional presses, which is
        // the shape of half the focus bugs this app has had — so every open and
        // close of one is on the record, with how long it is meant to last.
        AppProbe.focus("rail " + (enabled ? "enabled" : "disabled")
                       + (delay.map { String(format: " for %.2fs", $0) } ?? ""))
        AppProbe.rail = enabled ? "enabled" : "disabled"
        if enabled { sidebarAwaitingContent = false }
        sidebarReenableTask?.cancel()
        sidebarReenableTask = nil
        sidebarEnabled = enabled
        guard !enabled, let delay else { return }
        scheduleSidebarReenable(after: delay)
    }

    /// Waiting on HomeView's onContentReady before the rail may take focus
    /// (the entering-Home-fresh tab switch). Distinct from a pending timer,
    /// so the cold-launch 3s fallback can tell the two disables apart.
    @State private var sidebarAwaitingContent = false

    /// Re-enable the rail after `delay` WITHOUT touching its current state —
    /// for callers that merely want "focusable again soon" (onContentReady),
    /// where disabling first would break a rail the viewer has open.
    private func scheduleSidebarReenable(after delay: Double) {
        sidebarAwaitingContent = false
        sidebarReenableTask?.cancel()
        sidebarReenableTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            AppProbe.focus("rail re-enabled by timer")
            AppProbe.rail = "enabled"
            sidebarEnabled = true
            sidebarReenableTask = nil
        }
    }

    /// The rail's cold-launch fallback timer keeps running while the profile
    /// gate covers the screen, so once the gate dismisses the focus engine
    /// would land on the rail and pop it open. Briefly disable it again so
    /// focus goes to Home's content first.
    private func deferSidebarAfterProfileGate() {
        setSidebarEnabled(false, reenableAfter: Self.railSettle)
    }

    // MARK: - Tab roots

    private func homeRoot(filter: String?, path: Binding<NavigationPath>, active: Bool) -> some View {
        HomeView(
            viewModel: homeViewModel,
            typeFilter: filter,
            active: active,
            onSelect: { openDetail($0) { path.wrappedValue.append($0) } },
            // From the billboard: no slide. It already looks like the Detail
            // page's top, so the page just takes over in place.
            onSelectFeatured: { item in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { path.wrappedValue.append(Route.detail(item)) }
            },
            onResume: { resume($0) },
            onStartOver: { resume($0, fromBeginning: true) },
            onChooseSource: { playManuallyFromProgress($0) },
            onOpenFolder: { path.wrappedValue.append(Route.folder($0, $1)) },
            onContentReady: {
                // Give the freshly-loaded rows a beat to render and take
                // initial focus before the rail becomes focusable. This must
                // ONLY schedule the re-enable — it fires on every catalog
                // refresh, and disabling first would kick focus off an OPEN
                // rail whenever a background sync reloaded Home.
                scheduleSidebarReenable(after: 0.8)
            }
        )
        .probeScreen("Home")
    }

    /// Into Details, from anywhere: through black (`DetailTransition`),
    /// pushed under it without a slide.
    private func openDetail(_ item: MetaItem, append: @escaping (Route) -> Void) {
        DetailTransition.shared.open(item) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { append(Route.detail(item)) }
        }
    }

    private func searchRoot(active: Bool) -> some View {
        SearchView(
            viewModel: searchViewModel,
            active: active,
            onSelect: { openDetail($0) { searchPath.append($0) } },
            onOpenInPlace: { item in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { searchPath.append(Route.detail(item)) }
            }
        )
        .probeScreen("Search")
    }

    private var libraryRoot: some View {
        LibraryView(
            onSelect: { openDetail($0) { libraryPath.append($0) } },
            onBackAtRoot: { focusSidebar(2) }
        )
        .probeScreen("Library")
    }

    /// Shared navigation destinations. `path` is the binding for whichever
    /// tab's stack is presenting, so nested pushes stay within that tab.
    /// Every pushed screen goes through here, so ONE marker covers all of
    /// them — and a route added later is instrumented the moment it is
    /// reachable, with no second place to remember.
    private func destination(for route: Route, path: Binding<NavigationPath>) -> some View {
        destinationBody(for: route, path: path)
            .probeScreen(route.probeName) { route.probeDetail }
    }

    /// A collection's folder (or one of its parts, in full).
    private func folderView(_ collection: CueCollection, _ folder: CueCollectionFolder, part: String?,
                            path: Binding<NavigationPath>) -> some View {
        FolderView(collection: collection, folder: folder, part: part,
                   onSelect: { openDetail($0) { path.wrappedValue.append($0) } },
                   onOpenInPlace: { item in
                       var transaction = Transaction()
                       transaction.disablesAnimations = true
                       withTransaction(transaction) { path.wrappedValue.append(Route.detail(item)) }
                   },
                   onSeeAll: { path.wrappedValue.append(Route.folderPart(collection, folder, $0)) })
    }

    @ViewBuilder
    private func destinationBody(for route: Route, path: Binding<NavigationPath>) -> some View {
        switch route {
        case .detail(let item):
            DetailView(
                    item: item,
                    onSelectItem: { openDetail($0) { path.wrappedValue.append($0) } },
                    onSelectPerson: { id, name in path.wrappedValue.append(Route.person(id: id, name: name)) },
                    onSelectCompany: { company in
                        path.wrappedValue.append(Route.tmdbCompany(id: company.id, name: company.name,
                                                                   network: company.isNetwork))
                    },
                    // Back: `DetailTransition` (the billboard's way backwards,
                    // else the simple exit) — no system slide.
                    onReturnToBillboard: {
                        DetailTransition.shared.close(itemID: item.id) {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                            }
                        }
                    }
            )
        case .collection(let collection):
            CollectionView(collection: collection) { openDetail($0) { path.wrappedValue.append($0) } }
        case .folder(let collection, let folder):
            folderView(collection, folder, part: nil, path: path)
        case .folderPart(let collection, let folder, let part):
            folderView(collection, folder, part: part, path: path)
        case .person(let id, let name):
            CastDetailView(personID: id, personName: name) { openDetail($0) { path.wrappedValue.append($0) } }
        case .tmdbCompany(let id, let name, let network):
            TMDBBrowseView(companyID: id, title: name, network: network) { openDetail($0) { path.wrappedValue.append($0) } }
        case .catalogSeeAll(let addon, let catalog, let title):
            CatalogSeeAllView(addon: addon, catalog: catalog, title: title) { openDetail($0) { path.wrappedValue.append($0) } }
        case .streams(let meta, let video):
            StreamsView(
                meta: meta, video: video,
                // Auto Link Selector auto-played: flag a deferred pop; the real
                // pop happens when the player closes (see the player cover),
                // never while this view's resolve Task is still running.
                onAutoDismiss: { pendingAutoPlayPop = true }
            ) { entry, all in
                let key = ProgressStore.key(metaID: meta.id, video: video)
                startPlayback(PlaybackRequest(
                    meta: meta,
                    video: video,
                    entry: entry,
                    allEntries: all,
                    resumePosition: progressStore.progress(for: key)?.positionSeconds
                ))
            }
        case .streamsFromStart(let meta, let video):
            // Same picker, but playback ignores any saved progress (Start Over).
            // Carries `onAutoDismiss` like every other automatic route: without
            // it an auto-picked Start Over had nothing to pop, so the source
            // list uncovered itself behind the player and Back landed on it.
            StreamsView(
                meta: meta, video: video,
                onAutoDismiss: { pendingAutoPlayPop = true }
            ) { entry, all in
                startPlayback(PlaybackRequest(
                    meta: meta,
                    video: video,
                    entry: entry,
                    allEntries: all,
                    resumePosition: nil
                ))
            }
        case .streamsResume(let meta, let video, let fromStart):
            // Continue Watching: re-scrape and auto-play the best format match,
            // with the full list as the player's failover. Start Over plays the
            // matched link from 0:00; a normal resume from the saved position.
            let key = ProgressStore.key(metaID: meta.id, video: video)
            let progress = progressStore.progress(for: key)
            StreamsView(
                meta: meta, video: video,
                resumeAutoPlay: true,
                resumeSignature: progress?.streamSignature,
                onAutoDismiss: { pendingAutoPlayPop = true }
            ) { entry, all in
                startPlayback(PlaybackRequest(
                    meta: meta,
                    video: video,
                    entry: entry,
                    allEntries: all,
                    resumePosition: fromStart ? nil : progress?.positionSeconds
                ))
            }
        }
    }

    /// Pop the source page off the active tab's stack after an Auto Link
    /// Selector auto-play, so backing out of the player returns to the title
    /// page. Safe here because the player has fully closed by now. The player
    /// covers the stack while it's up, so the top entry is still the source page.
    private func popActivePathForAutoPlay() {
        switch selectedTab {
        case 0: if !homePath.isEmpty { homePath.removeLast() }
        case 1: if !searchPath.isEmpty { searchPath.removeLast() }
        case 2: if !libraryPath.isEmpty { libraryPath.removeLast() }
        case 4: if !moviesPath.isEmpty { moviesPath.removeLast() }
        case 5: if !seriesPath.isEmpty { seriesPath.removeLast() }
        default: break
        }
    }

    /// Plays a picked link — from its saved position, or from the start.
    private func play(_ meta: MetaItem, _ video: MetaVideo?, _ entry: StreamEntry, _ all: [StreamEntry],
                      fromStart: Bool) {
        let key = ProgressStore.key(metaID: meta.id, video: video)
        startPlayback(PlaybackRequest(meta: meta, video: video, entry: entry, allEntries: all,
                                      resumePosition: fromStart ? nil : progressStore.progress(for: key)?.positionSeconds))
    }

    private func startPlayback(_ request: PlaybackRequest) {
        // A session parked in the Picture in Picture window is still decoding
        // and still owns the audio route, and nothing in the app ever ended
        // one — `stop()` had no callers at all. Opening a different title over
        // it left two engines live: two soundtracks at once and two pipelines
        // on a 3 GB A10X, and with the hybrid cache on, `beginSession` for the
        // new origin tore down the parked session's connections and deleted
        // the cache file its reader was still reading.
        if PiPHandoff.shared.isActive {
            // Window first: `finish()` on its own runs the teardown but leaves
            // AVKit's window up over a view model that no longer exists.
            PiPHandoff.shared.viewModel?.pictureInPicture.stop()
            // Then the teardown `onDidStop` would have run — synchronously,
            // BEFORE the new cover. Teardown resets state the two sessions
            // share (the cache server's session, the audio session, the sync
            // pause), so letting it land after the new load has started strips
            // that out from under the new engine. AVKit's own `didStop` still
            // arrives later and finds nothing parked, which is a no-op.
            PiPHandoff.shared.finish()
        }
        playback = request
    }

    /// Route an incoming `cue://` / `stremio://` deep link.
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLinkService.parse(url) else { return }
        switch link {
        case .meta(let type, let id):
            // Open the title on the Home tab. DetailView fetches full meta +
            // canonicalizes tmdb→tt from this id.
            let meta = MetaItem(id: id, type: type, name: "")
            selectedTab = 0
            // Defer the push one runloop turn so it lands AFTER the tab switch
            // has rebuilt the Home NavigationStack. Mutating `selectedTab` and
            // the path in the same tick is the documented grey/ghost shape the
            // player cover's own deferral exists to avoid.
            DispatchQueue.main.async { homePath.append(Route.detail(meta)) }
        case .addonInstall(let manifestURL):
            requestAddonInstall(manifestURL)
        }
    }

    /// Step 1 of a deep-link add-on install: read the manifest so the prompt
    /// can NAME the add-on, then ask. Nothing is installed here — fetching a
    /// manifest is a plain read, and the viewer still has to say yes.
    private func requestAddonInstall(_ manifestURL: String) {
        guard !addonInstallInFlight, pendingAddonInstall == nil else { return }
        addonInstallInFlight = true
        Task { @MainActor in
            defer { addonInstallInFlight = false }
            let normalized = AddonManager.normalizeManifestURL(manifestURL)
            guard let manifest = try? await StremioAPI.manifest(url: normalized) else {
                // Previously this failure was swallowed entirely — the link
                // just did nothing and the viewer had no idea why.
                ToastCenter.shared.show("Couldn't read that add-on's manifest", icon: "exclamationmark.triangle")
                return
            }
            pendingAddonInstall = PendingAddonInstall(
                manifestURL: normalized,
                name: manifest.name.isEmpty ? normalized : manifest.name,
                isUpdate: addonManager.addons.contains { $0.manifestURL == normalized }
            )
        }
    }

    /// Step 2: the viewer pressed Install/Update. Success and failure are both
    /// reported — the old silent `try?` left either outcome invisible.
    private func confirmAddonInstall(_ pending: PendingAddonInstall) {
        pendingAddonInstall = nil
        Task { @MainActor in
            do {
                try await addonManager.install(manifestURL: pending.manifestURL)
                ToastCenter.shared.show(
                    pending.isUpdate ? "Updated \(pending.name)" : "Installed \(pending.name)",
                    icon: "checkmark.circle"
                )
            } catch {
                ToastCenter.shared.show("Couldn't install \(pending.name)", icon: "exclamationmark.triangle")
            }
        }
    }

    private func resume(_ progress: WatchProgress, fromBeginning: Bool = false) {
        Task { await resumeResolved(progress, fromBeginning: fromBeginning) }
    }


    /// Continue Watching resume. TMDB-sourced items are stored as `tmdb:<n>`
    /// (and episodes as `tmdb:<n>:<s>:<e>`), but Cinemeta and Torrentio only
    /// speak IMDb `tt` ids — so resuming one directly found no metadata and no
    /// streams (the "metadata not found" a show hit that had never been opened
    /// through its Detail page, which is where this same resolve normally
    /// happens). Canonicalize to the `tt` id first, then migrate the stored
    /// entry so the card doesn't fork into a duplicate under the new key.
    @MainActor
    private func resumeResolved(_ progress: WatchProgress, fromBeginning: Bool) async {
        let (meta, video) = await canonicalResumeIdentity(progress)
        // Resume ALWAYS re-scrapes a fresh link now: a remembered URL from a
        // debrid/Comet-style addon expires, so replaying it "fails to load" and
        // (with no failover alternates) drops you back to 0:00. Instead route to
        // the source picker, which auto-plays the link best matching what was
        // last watched, with the full list as failover. Start Over takes the
        // same matched-link path but plays from 0:00.
        homeLikePath.wrappedValue.append(Route.streamsResume(meta, video, fromStart: fromBeginning))
    }

    /// Continue Watching hold → "Choose Source": the source picker, through
    /// the SAME identity repair as a resume (`tmdb:` metaIDs, rows typed "tv",
    /// synced rows missing season/episode) — the raw stored row found no
    /// sources.
    private func playManuallyFromProgress(_ progress: WatchProgress) {
        Task { @MainActor in
            let (meta, video) = await canonicalResumeIdentity(progress)
            SourcePicker.shared.open(meta, video)
        }
    }

    /// Whether a progress row is a series. Synced rows arrive typed "tv",
    /// "show" or "anime" as well as "series" — a bare `type != "series"` test
    /// sent every one of those down TMDB's MOVIE endpoint (disjoint id space →
    /// no tt id, or the wrong film's) and put the raw type into the addon
    /// stream path (`/stream/tv/…` → 404), which is why SOME shows resumed
    /// from Continue Watching found no sources while their Detail page — which
    /// tests `isSeries` properly — worked.
    private static func isSeriesProgressType(_ type: String) -> Bool {
        ["series", "tv", "show", "tvshow", "anime"].contains(type.lowercased())
    }

    /// The canonical (meta, video) identity for a stored Continue Watching
    /// row — shared by resume and the hold-menu's Play Manually. Repairs the
    /// id/type shapes sync sources leave behind, and migrates the stored row
    /// so the corrected key doesn't fork a duplicate card.
    @MainActor
    private func canonicalResumeIdentity(_ progress: WatchProgress) async -> (MetaItem, MetaVideo?) {
        let isSeries = Self.isSeriesProgressType(progress.type)

        // Recover a dropped season/episode from the progress KEY. Synced rows
        // can carry `season`/`episode` as nil while the key still spells them
        // ("tt123:2:5" — the backend sent video_id but not the columns). With
        // them nil the episode identity below collapsed to the bare show id,
        // and a show-level stream query returns nothing for a series.
        var season = progress.season
        var episode = progress.episode
        if isSeries, season == nil || episode == nil {
            let parts = progress.id.split(separator: ":")
            if parts.count >= 3,
               let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) {
                season = s
                episode = e
            }
        }

        var metaID = progress.metaID
        // TMDB-sourced ids can't be served by Cinemeta/Torrentio — resolve to
        // the IMDb tt id (DetailView does the same).
        if metaID.hasPrefix("tmdb:"), let n = Int(metaID.dropFirst("tmdb:".count)),
           let tt = await TMDBService.imdbID(tmdbID: n, isMovie: !isSeries) {
            metaID = tt
        }

        // Reconstruct the CANONICAL Stremio episode id (`showId:season:episode`)
        // from the parts rather than trusting `progress.id`. Synced entries key
        // episodes by the backend's `video_id`, which falls back to the bare
        // SHOW id when the backend didn't send one — so resuming a synced
        // episode used to fetch show-level streams (none for a series) and fail
        // with "no sources", while opening via Details (which builds the id
        // correctly) worked. Only for tt-based shows; leave exotic id schemes
        // (kitsu: etc.) and movies alone.
        var episodeID = progress.id
        if metaID.hasPrefix("tt"), let season, let episode {
            episodeID = "\(metaID):\(season):\(episode)"
        } else if metaID != progress.metaID, !isSeries {
            // tmdb → tt movie (no episode): the id is just the movie id. A
            // series row must NOT take this collapse — with no recoverable
            // episode it would rewrite the stored key to the show id.
            episodeID = metaID
        }

        // Migrate the stored entry if the identity changed, so the corrected
        // key doesn't fork a duplicate Continue Watching card.
        if episodeID != progress.id || metaID != progress.metaID {
            progressStore.recanonicalize(oldID: progress.id, newID: episodeID, newMetaID: metaID)
        }

        let meta = MetaItem(
            id: metaID,
            // Normalised: the raw stored type goes verbatim into the addon
            // stream URL (`/stream/<type>/<id>.json`), and only "series" /
            // "movie" exist there.
            type: isSeries ? "series" : "movie",
            name: progress.name,
            poster: progress.poster,
            background: progress.background,
            logo: progress.logo
        )
        // Rebuild the episode identity so progress keeps saving under the
        // episode key instead of forking a second entry under the show.
        let video: MetaVideo? = season != nil || episode != nil
            ? MetaVideo(
                id: episodeID,
                title: progress.episodeTitle,
                season: season,
                episode: episode
            )
            : nil
        return (meta, video)
    }
}


// NOTE: intentionally NOT #if DEBUG — the call sites above are unconditional.
/// Dev: `-focusLog` logs every focus update and every FAILED move (the focus
/// engine found no candidate) app-wide. Sim key delivery is flaky and
/// screenshots only show styled focus, so this is the only reliable truth
/// about where focus actually is.
@MainActor
enum FocusTrace {
    private static var tokens: [NSObjectProtocol] = []
    static let enabled = ProcessInfo.processInfo.arguments.contains("-focusLog")

    static func installIfRequested() {
        guard tokens.isEmpty, enabled else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIFocusSystem.didUpdateNotification,
                                         object: nil, queue: .main) { note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            NSLog("[FocusTrace] UPDATE %@ -> %@ (heading %ld)",
                  describe(ctx.previouslyFocusedItem), describe(ctx.nextFocusedItem),
                  ctx.focusHeading.rawValue)
        })
        tokens.append(center.addObserver(forName: UIFocusSystem.movementDidFailNotification,
                                         object: nil, queue: .main) { note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            NSLog("[FocusTrace] MOVE FAILED from %@ heading %ld",
                  describe(ctx.previouslyFocusedItem), ctx.focusHeading.rawValue)
        })
        NSLog("[FocusTrace] installed")
    }

    private static func describe(_ item: UIFocusItem?) -> String {
        guard let item else { return "NONE" }
        let cls = String(describing: type(of: item))
        // UIFocusItem.frame is in the item's own coordinate space; convert via
        // its container for a window-relative rectangle.
        var frame = item.frame
        if let view = item as? UIView, let win = view.window {
            frame = view.convert(view.bounds, to: win)
        } else if let container = item.parentFocusEnvironment as? UIView, let win = container.window {
            frame = container.convert(frame, to: win)
        }
        let parent = item.parentFocusEnvironment.map { String(describing: type(of: $0)) } ?? "-"
        return String(format: "%@ @(%.0f,%.0f %.0fx%.0f) in %@", cls, frame.minX, frame.minY, frame.width, frame.height, parent)
    }
}
// (end -focusLog tracer)


// MARK: - Launch (docs/LOADING-PLAN.md §4)

/// THE LAUNCH: on a cold start, while a small ring shows, the closest things
/// get ready — Home's rows and billboard from disk, the billboard's pictures
/// and colours decoded, the first row's posters, the one-time artwork — and
/// Home is built under it. It ends when that's done (at least `minimum`
/// shown), or at `cap` — never waiting on the network: what isn't on disk
/// loads as usual afterwards. Every step reports a count and its time
/// (Render Lab → Launch: show numbers).
@MainActor
final class LaunchPreloader: ObservableObject {
    static let shared = LaunchPreloader()

    @Published private(set) var curtain = true
    @Published private(set) var progress: Double = 0
    @Published private(set) var lines: [String] = []

    static let minimum: Double = 0.6
    static let cap: Double = 2.5

    private var started = false
    private var finished = false
    private let launchedAt = CACurrentMediaTime()
    private var elapsed: Double { CACurrentMediaTime() - launchedAt }

    func run(home: HomeViewModel, addonManager: AddonManager) {
        guard !started else { return }
        started = true
        Task { await steps(home: home, addonManager: addonManager) }
        Task {
            try? await Task.sleep(for: .seconds(Self.cap))
            finish(note: "cap reached")
        }
    }

    /// Covered by the welcome screen or the profile gate: no curtain.
    func skip() { finish(note: "covered") }

    private func finish(note: String) {
        guard !finished else { return }
        finished = true
        line(String(format: "Total     %.2f s  (%@)", elapsed, note))
        progress = 1
        curtain = false
        // Input back on: the focus engine doesn't pick a focus by itself —
        // the first press only woke it. Asked to, once the page is enabled.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            window?.rootViewController?.setNeedsFocusUpdate()
            window?.rootViewController?.updateFocusIfNeeded()
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.numbersLinger))
            numbersShown = false
        }
    }

    private func line(_ text: String) {
        lines.append(text)
        PlayerProbe.event("launch", text)
    }

    /// The numbers stay this long after Home appears (to read them).
    static let numbersLinger: Double = 6
    @Published private(set) var numbersShown = true

    private func steps(home: HomeViewModel, addonManager: AddonManager) async {
        // ① From disk: Home's rows and billboard picks (Home reads its cache
        // as it's built under the curtain) — and the titles to open first.
        var t = CACurrentMediaTime()
        while home.entries.isEmpty, elapsed < 1.0 { try? await Task.sleep(for: .milliseconds(25)) }
        // The billboard's own picks (made once the catalogs are in): waited
        // for — they replaced the rows' highlights a moment after Home
        // appeared, a visible swap. At most until 2 s (room for the decodes
        // before the cap).
        let picksStarted = CACurrentMediaTime()
        while home.billboardPicks.isEmpty, elapsed < 2.0 { try? await Task.sleep(for: .milliseconds(25)) }
        let picksWait = (CACurrentMediaTime() - picksStarted) * 1000
        // (Home's own: its first `BillboardPicks.count` — the model holds
        // every tab's.)
        let picks = home.billboard(type: nil).map(\.item)
        let rows: [HomeRow] = home.entries.compactMap { if case .catalog(let row) = $0 { return row } else { return nil } }
        var records = 0
        let firstTitles = Array(picks.prefix(6)) + Array((rows.first?.items ?? []).prefix(6))
        for item in firstTitles {
            if let addon = addonManager.metaAddons(for: item.type, id: item.id).first,
               await StremioAPI.warmMeta(addon: addon, type: item.type, id: item.id) { records += 1 }
        }
        line(String(format: "Disk      rows %d · picks %d%@ (waited %.0f ms) · records %d/%d · %.0f ms",
                    rows.count, picks.count, home.billboardPicks.isEmpty ? " (highlights)" : "",
                    picksWait, records, firstTitles.count, (CACurrentMediaTime() - t) * 1000))
        progress = 0.15

        // ③ One-time artwork (cheap; first so it's off the way), on the main
        // actor — under the curtain.
        t = CACurrentMediaTime()
        _ = StageArt.shade
        _ = FixedFocusBackdropArt.grain
        _ = FixedFocusBackdropArt.shadow
        _ = FixedFocusBackdropArt.glow
        _ = FixedFocusCardEdge.shadowImage
        _ = BillboardShade.sunImage
        _ = DetailTransition.shadeImage
        line(String(format: "Setup     artwork 7 · %.0f ms", (CACurrentMediaTime() - t) * 1000))
        progress = 0.25

        // ② Decodes, from disk only, a few at a time: the billboard's first
        // backdrops (the stage's own size), every logo, the first colours, the
        // first row's posters (the cards' size).
        t = CACurrentMediaTime()
        var jobs: [(kind: String, run: () async -> Bool)] = []
        for item in picks.prefix(3) {
            if let url = TMDBService.originalSize(item.background) ?? item.poster {
                jobs.append(("backdrop", { await ImageCache.shared.preloadFromDisk(url, maxDimension: StagePictureView.pictureSize.width) }))
            }
        }
        for item in picks {
            if let logo = item.logo {
                jobs.append(("logo", { await ImageCache.shared.preloadFromDisk(logo, maxDimension: TitleBlock.logoWidth) }))
            }
        }
        let flags = RenderProbe.shared.flags
        for item in picks.prefix(3) {
            if let url = item.background ?? item.poster {
                jobs.append(("colours", {
                    guard await ImageCache.shared.preloadFromDisk(url, maxDimension: 64) else { return false }
                    _ = await FixedFocusTint.colors(for: url, flags: flags)
                    if FixedFocusTint.Mode(rawValue: flags.tintMode) == .layout {
                        _ = await FixedFocusTint.layout(for: url, flags: flags)
                    }
                    return true
                }))
            }
        }
        for item in (rows.first?.items ?? []).prefix(8) {
            if let url = item.poster ?? item.background {
                jobs.append(("poster", { await ImageCache.shared.preloadFromDisk(url, maxDimension: FixedFocusMetrics.height) }))
            }
        }
        var done: [String: (ok: Int, all: Int)] = [:]
        let total = max(jobs.count, 1)
        var finishedJobs = 0
        // A few at a time (the decodes themselves are off the main actor).
        var next = 0
        await withTaskGroup(of: (String, Bool).self) { group in
            func start() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask { (job.kind, await job.run()) }
            }
            for _ in 0..<3 { start() }
            for await (kind, ok) in group {
                var entry = done[kind] ?? (0, 0)
                entry.all += 1
                if ok { entry.ok += 1 }
                done[kind] = entry
                finishedJobs += 1
                progress = 0.25 + 0.75 * Double(finishedJobs) / Double(total)
                start()
            }
        }
        let summary = [("backdrop", "backdrops"), ("logo", "logos"), ("colours", "colours"), ("poster", "posters")]
            .compactMap { kind, label -> String? in
                guard let entry = done[kind] else { return nil }
                return "\(label) \(entry.ok)/\(entry.all)"
            }.joined(separator: " · ")
        line(String(format: "Decode    %@ · %.0f ms", summary, (CACurrentMediaTime() - t) * 1000))

        // Shown at least `minimum` (no flash of a ring).
        if elapsed < Self.minimum { try? await Task.sleep(for: .seconds(Self.minimum - elapsed)) }
        finish(note: "ready")
    }
}

/// The launch screen: a small ring, and — Render Lab → Launch: show numbers
/// — what was loaded and how long it took.
struct LaunchCurtain: View {
    @ObservedObject private var launch = LaunchPreloader.shared
    @ObservedObject private var probe = RenderProbe.shared

    var body: some View {
        ZStack {
            if launch.curtain {
                ZStack {
                    Color.black
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 5)
                        Circle().trim(from: 0, to: launch.progress)
                            .stroke(Color.white.opacity(FixedFocusText.primary),
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.2), value: launch.progress)
                    }
                    .frame(width: 56, height: 56)
                }
                .transition(.opacity)
            }
            // The numbers: on the curtain, and a little after on Home (to read).
            if probe.flags.launchNumbers, launch.numbersShown, !launch.lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(launch.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .font(.system(size: 20, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 84)
                .padding(.bottom, 130)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.3), value: launch.numbersShown)
    }
}

/// Step ⑤/⑥ of the loading plan (docs/LOADING-PLAN.md): a background queue
/// that gets what Details needs ready BEFORE the press — around focus first,
/// then the rows top to bottom. Never in the way:
/// - it waits until focus has stopped moving (`settle`) — nothing starts
///   during a scroll or a swap;
/// - 3 jobs at a time, each a few small requests or a decode off the main
///   thread; nothing while the player is up;
/// - a cap per launch (`cap` titles that needed the network);
/// - decoded near focus only (the focused title and its neighbours); further
///   out only to disk.
/// Three depths per title, each done at most once per launch:
/// - record: the episode list / meta, TMDB details, backdrop and logo to disk;
/// - pictures: + the backdrop decoded at the stage's size, the logo, colours;
/// - full (after a rest of `restTime` on it): + the season extras, the
///   blurred backdrop, the first episode stills to disk.
@MainActor
final class TitlePreloader {
    static let shared = TitlePreloader()

    enum Depth: Int, Comparable {
        case record, pictures, full
        static func < (a: Depth, b: Depth) -> Bool { a.rawValue < b.rawValue }
    }

    struct Context {
        let addonManager: AddonManager
        let mdb: MDBListSettings
        let tmdb: TMDBSettings
        var useEpisodeExtras: Bool { tmdb.useEpisodes }
        let progress: ProgressStore
        let watched: WatchedStore
    }

    /// Set by Home (its stores); nothing runs before.
    var context: Context?

    static let parallel = 3
    /// Focus still for this long: the queue starts.
    static let settle: Double = 0.35
    /// Resting on a title this long: it's warmed fully.
    static let restTime: Double = 0.5
    /// Titles per launch that went to the network.
    static let cap = PerformanceProfile.isLowPower ? 120 : 250
    /// Rows top to bottom: this many titles of each.
    static let perRow = 6

    private var queue: [(item: MetaItem, depth: Depth)] = []
    private var done: [String: Depth] = [:]
    private var running = 0
    private var settleTask: Task<Void, Never>?
    private var restTask: Task<Void, Never>?
    private var batchedRows = Set<String>()
    private(set) var networkTitles = 0
    private var stats = (jobs: 0, disk: 0, net: 0, ms: 0.0)

    /// Focus moved to `index` in row `row` of `rows` (Home's rows engine).
    func focused(rows: [HomeRow], row: Int, index: Int) {
        guard context != nil, rows.indices.contains(row), rows[row].items.indices.contains(index) else { return }
        settleTask?.cancel()
        restTask?.cancel()
        let item = rows[row].items[index]
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settle))
            guard !Task.isCancelled, let self else { return }
            self.plan(rows: rows, row: row, index: index)
        }
        if Self.wanted(item) {
            restTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.restTime))
                guard !Task.isCancelled, let self else { return }
                self.queue.insert((item, .full), at: 0)
                self.pump()
            }
        }
    }

    /// Titles only (not episodes, folders, people).
    private static func wanted(_ item: MetaItem) -> Bool { item.type == "movie" || item.type == "series" }

    /// The order, from where focus is: the title and its neighbours (decoded),
    /// a little further along the row and the next row (records), then the
    /// rows top to bottom (records). Replaces what was waiting.
    private func plan(rows: [HomeRow], row: Int, index: Int) {
        var list: [(MetaItem, Depth)] = []
        let items = rows[row].items
        func add(_ r: Int, _ i: Int, _ depth: Depth) {
            guard rows.indices.contains(r), rows[r].items.indices.contains(i) else { return }
            list.append((rows[r].items[i], depth))
        }
        add(row, index, .pictures)
        for offset in [1, -1] { add(row, index + offset, .pictures) }
        for offset in [2, 3, -2, 4, -3] { add(row, index + offset, .record) }
        for i in 0..<4 { add(row + 1, i, .record) }
        for r in rows.indices where r != row {
            for i in 0..<min(Self.perRow, rows[r].items.count) { add(r, i, .record) }
        }
        for i in items.indices.prefix(Self.perRow) { add(row, i, .record) }
        queue = list.filter { item, depth in
            Self.wanted(item) && done[item.id].map { $0 < depth } ?? true
        }
        batchRatings(rows)
        pump()
    }

    /// The ratings of every title on the rows: one MDBList batch (200 a
    /// request) per new set of rows.
    private func batchRatings(_ rows: [HomeRow]) {
        guard let context else { return }
        let key = rows.map(\.id).joined(separator: ",")
        guard batchedRows.insert(key).inserted else { return }
        let items = rows.flatMap(\.items).filter(Self.wanted)
        Task.detached(priority: .utility) { await MDBListService.prefetch(items, settings: context.mdb) }
    }

    private func pump() {
        while running < Self.parallel, !queue.isEmpty {
            guard PlayerViewModel.liveInstances == 0 else { queue.removeAll(); return }
            let (item, depth) = queue.removeFirst()
            if let had = done[item.id], had >= depth { continue }
            let first = done[item.id] == nil
            if first, networkTitles >= Self.cap, depth < .pictures { continue }
            done[item.id] = depth
            running += 1
            Task { [weak self] in
                let t = CACurrentMediaTime()
                let net = await self?.warm(item, depth: depth, first: first) ?? false
                guard let self else { return }
                self.running -= 1
                self.note(item, depth: depth, net: net, ms: (CACurrentMediaTime() - t) * 1000)
                self.pump()
            }
        }
    }

    private func note(_ item: MetaItem, depth: Depth, net: Bool, ms: Double) {
        stats.jobs += 1
        if net { stats.net += 1; networkTitles += 1 } else { stats.disk += 1 }
        stats.ms += ms
        PlayerProbe.event("preload", String(format: "%@ %@ %.0f ms%@ · total %d (meta on disk %d, from network %d of %d)",
                                            "\(depth)", item.name, ms, net ? " (meta from network)" : "",
                                            stats.jobs, stats.disk, stats.net, Self.cap))
    }

    /// One title to `depth`. True when something came from the network.
    private func warm(_ item: MetaItem, depth: Depth, first: Bool) async -> Bool {
        guard let context else { return false }
        var net = false
        // The record (cheap when it's on disk: read, no request).
        let onDisk: Bool
        if let addon = context.addonManager.metaAddons(for: item.type, id: item.id).first {
            onDisk = await StremioAPI.warmMeta(addon: addon, type: item.type, id: item.id)
        } else { onDisk = false }
        let meta = await SeriesEpisodes.fullMeta(for: item, addonManager: context.addonManager)
        if !onDisk { net = true }
        if TMDBService.hasAPIKey, first {
            _ = await TMDBService.detail(imdbID: meta.id, type: meta.type)
        }
        // The page's pictures: what Details shows (its meta's) and what the
        // card had, if different.
        let backdrops = Array(Set([meta.background ?? meta.poster, item.background ?? item.poster].compactMap { $0 }))
        let logo = meta.logo ?? item.logo
        if depth == .record {
            for url in backdrops { _ = await ImageCache.shared.fetchToDisk(url) }
            if let logo { _ = await ImageCache.shared.fetchToDisk(logo) }
            return net
        }
        for url in backdrops {
            await ImageCache.shared.preload(url, maxDimension: StagePictureView.pictureSize.width)
        }
        if let logo { await ImageCache.shared.preload(logo, maxDimension: TitleBlock.logoWidth) }
        let flags = RenderProbe.shared.flags
        if let url = backdrops.first { _ = await FixedFocusTint.colors(for: url, flags: flags) }
        guard depth == .full else { return net }
        _ = await BlurredBackdrop.image(for: meta.background ?? meta.poster, strength: flags.detailsPictureBlur)
        // A show: the season extras (Details asks for every season — the
        // first 10 here) and the stills around Play's episode.
        guard meta.isSeries else { return net }
        if context.useEpisodeExtras, TMDBService.hasAPIKey {
            let id = meta.id, type = meta.type
            await withTaskGroup(of: Void.self) { group in
                for season in meta.seasons.prefix(10) {
                    group.addTask { _ = await TMDBService.seasonEpisodes(imdbID: id, type: type, season: season) }
                }
            }
        }
        let order = SeriesEpisodes.inPlayOrder(meta)
        if let target = SeriesEpisodes.playTarget(meta.id, in: order, progress: context.progress, watched: context.watched),
           let at = order.firstIndex(where: { $0.id == target.id }) {
            let season = target.season ?? 0
            let extras = context.useEpisodeExtras
                ? await TMDBService.seasonEpisodes(imdbID: meta.id, type: meta.type, season: season) : [:]
            for episode in order[max(0, at - 1)..<min(order.count, at + 5)] {
                let still = episode.episode.flatMap { extras[$0]?.still }
                if let url = TMDBService.originalSize(still) ?? episode.thumbnail {
                    _ = await ImageCache.shared.fetchToDisk(url)
                }
            }
        }
        return net
    }
}
