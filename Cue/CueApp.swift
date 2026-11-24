import AVKit
import SwiftUI

/// The window, the last view-side responder a press reaches: a Back no view
/// took (focus on a view whose handlers are disabled, or on nothing — a page
/// or the player coming in, a panel opening) went on to the system and sent
/// the app to the tvOS home screen. Such a Back now does nothing (every
/// Back the app means is handled — the top bar's goes down to the page).
/// (The app delegate isn't in the chain: SwiftUI's adaptor puts its own.)
enum BackCatch {
    static func install() {
        hook(#selector(UIResponder.pressesBegan(_:with:)))
        hook(#selector(UIResponder.pressesEnded(_:with:)))
    }

    static func swallows(_ presses: NSSet) -> Bool {
        presses.contains { ($0 as? UIPress)?.type == .menu }
    }

    private typealias Press = @convention(c) (AnyObject, Selector, NSSet, UIPressesEvent?) -> Void

    /// UIWindow's method (its own, or the one it inherits) wrapped; the
    /// original runs under its own selector (UIResponder's passes the press
    /// on by it).
    private static func hook(_ selector: Selector) {
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Press.self)
        let wrapped: @convention(block) (AnyObject, NSSet, UIPressesEvent?) -> Void = { window, presses, event in
            if swallows(presses) { return }
            original(window, selector, presses, event)
        }
        let imp = imp_implementationWithBlock(wrapped)
        if !class_addMethod(UIWindow.self, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }
}

/// The remote's last press (any button), and work waiting until it has
/// been still a while (`whenIdle`).
@MainActor
enum InputHold {
    /// The last press's start (any button).
    private(set) static var lastPress: CFTimeInterval = 0
    /// Its button, for the Log's DROP lines.
    private(set) static var lastPressName = ""

    /// `body` once the remote has been still for `idle` seconds — for
    /// main-thread work that's out of sight but long enough to delay a
    /// press (taking down a page's views: ~0.3 s).
    static func whenIdle(for idle: Double = 1.5, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            var wait = idle
            while true {
                try? await Task.sleep(for: .seconds(wait))
                let still = CACurrentMediaTime() - lastPress
                if still >= idle { break }
                wait = idle - still
            }
            body()
        }
    }

    static func install() {
        hookSendEvent()
    }

    /// Play/Pause three times quickly, outside the player: a MARK in the log
    /// (the player has its shelf's flag: there Play/Pause pauses).
    private static var playPauses: [CFTimeInterval] = []
    private static func playPaused() {
        let now = CACurrentMediaTime()
        playPauses = playPauses.filter { now - $0 < 1 } + [now]
        guard playPauses.count >= 3, ProbeGate.isEnabled, !PlayerController.isPlaying else { return }
        playPauses = []
        CueLog.mark(from: "with Play/Pause")
        ToastCenter.shared.show("Marked in the log", icon: "flag")
    }

    private static func name(_ type: UIPress.PressType) -> String {
        switch type {
        case .upArrow: "Up"
        case .downArrow: "Down"
        case .leftArrow: "Left"
        case .rightArrow: "Right"
        case .select: "Select"
        case .menu: "Back"
        case .playPause: "Play/Pause"
        default: "press \(type.rawValue)"
        }
    }

    private typealias Send = @convention(c) (AnyObject, Selector, UIEvent) -> Void
    private static func hookSendEvent() {
        let selector = #selector(UIWindow.sendEvent(_:))
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Send.self)
        let wrapped: @convention(block) (AnyObject, UIEvent) -> Void = { window, event in
            if let presses = (event as? UIPressesEvent)?.allPresses,
               presses.contains(where: { $0.phase == .began }) {
                MainActor.assumeIsolated {
                    lastPress = CACurrentMediaTime()
                    if let press = presses.first(where: { $0.phase == .began }) { lastPressName = name(press.type) }
                    if presses.contains(where: { $0.type == .playPause && $0.phase == .began }) { playPaused() }
                }
            }
            original(window, selector, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(wrapped))
    }
}

@main
struct CueApp: App {
    /// Reclaim orphaned player scratch space before anything else runs
    /// (`PlayerTempSweep`): launch is the one moment none of it is live.
    init() {
        // FIRST of all, before ANY UserDefaults write below: shrink an
        // oversized add-on blob a pre-compression build left behind. On a box
        // already at the ~1 MB CFPreferences abort, the first unrelated write
        // (the migration stamp, a store save) aborts the process, so the app
        // crash-loops on launch and the viewer can never reach Settings to
        // remove the add-on. This is a reducing write, which CFPreferences
        // accepts, so it breaks the loop. See AddonManager.
        AddonManager.reclaimUncompressedStorage()
        // Same emergency reclaim for the content stores. A long history
        // can put the watched history or the library past the ~1 MB
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
        CacheStorage.scheduleTidy()
        // The Log (Settings → Developer): on unless switched off. Resolved
        // before anything logs; the file log, its LAN server (:8123) and the
        // main thread's watchdog start with it.
        ProbeGate.configureFromDefaults()
        CueLog.start()
        LogServer.shared.start()
        Watchdog.start()
        // The browse half of the same probe. Armed HERE, not on a screen's
        // appear, so the tail covers launch itself — a cold start that hangs
        // before any view exists is exactly the session with no other witness.
        AppProbe.installLevels()
        BackCatch.install()
        InputHold.install()
        // The background, in before the gate (it fades in under the line).
        BackgroundStore.shared.load()
    }

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

    var body: some Scene {
        WindowGroup {
            RootView()

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
        case .browse(let subject, _): return subject.kind == .person ? "Cast" : "Studio"
        case .genre: return "Genre"
        case .keyword: return "Tag"
        case .discover: return "Discover"
        }
    }

    var probeDetail: String {
        switch self {
        case .detail(let item): return "\(item.name) [\(item.type) \(item.id)]"
        case .browse(let subject, _): return subject.name
        case .genre(_, let name, _, _): return name
        case .keyword(_, let name, _, _): return name
        case .discover(let name, _, _): return name
        default: return ""
        }
    }
}

/// Details as a layer over a home-like tab (`detailLayers`). Its root is
/// the first page of the trail above the tab — Details, or a page opened
/// from it once the trail moved on (`detailLayerPath`).
struct DetailLayer {
    var root: Route
    var path: [Route] = []
    let id = UUID()
    /// Back: the page under it shown again at once, the layer itself gone
    /// only once the fade is over (taken down with the close, the update
    /// held the main thread ~0.3 s before the fade could start).
    var leaving = false
}

extension Route {
    /// A page of the trail above where you started (`RootView.trail`):
    /// Details, a browse page — not a source list.
    var isTrailPage: Bool {
        switch self {
        case .detail, .browse, .genre, .keyword, .discover: return true
        default: return false
        }
    }

    /// Its key for `PageFade`'s stills (Details: its title's id).
    var fadeKey: AnyHashable {
        if case .detail(let item) = self { return item.id }
        return self
    }
}

enum Route: Hashable {
    case detail(MetaItem)
    /// From Details: `backdrop`, that title's picture (behind the page,
    /// blurred).
    /// A person's, studio's or network's titles: Discover round them.
    case browse(DiscoverModel.Subject, backdrop: String? = nil)
    /// A genre's titles (films or shows).
    case genre(id: Int, name: String, isMovie: Bool, backdrop: String? = nil)
    /// A tag's (TMDB keyword's) titles.
    case keyword(id: Int, name: String, isMovie: Bool, backdrop: String? = nil)
    /// Discover filled in from a title (a card's hold menu): its sentence's
    /// words by slot, `name` the title's.
    case discover(name: String, picks: [String: String], backdrop: String? = nil)

    /// What a pushed page draws behind itself, shown at the press
    /// (`PageFade.push`).
    var pageBackground: AnyView? {
        switch self {
        case .browse(_, let backdrop),
             .genre(_, _, _, let backdrop), .keyword(_, _, _, let backdrop), .discover(_, _, let backdrop):
            AnyView(TitleBandsBackground(url: backdrop))
        default: nil
        }
    }
}

struct RootView: View {
    @ObservedObject private var modeSwap = ModeSwap.shared
    @ObservedObject private var sourcePicker = SourcePicker.shared
    @ObservedObject private var stage = PlayStage.shared
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
    @EnvironmentObject private var tmdbSettings: TMDBSettingsStore
    @EnvironmentObject private var mdblistSettings: MDBListSettingsStore
    @Environment(\.scenePhase) private var scenePhase

    // One navigation stack per tab (tvOS expects TabView at the top level with
    // an independent NavigationStack inside each tab; a shared stack under one
    // NavigationStack makes the tab bar hard to reach and focus feel stuck).
    @State private var homePath: [Route] = []
    @State private var searchPath: [Route] = []
    @State private var libraryPath: [Route] = []
    @State private var discoverPath: [Route] = []
    @State private var upcomingPath: [Route] = []
    @State private var settingsPath: [Route] = []
    /// Details over Home, Movies or Series (by tab): a layer over the tab's
    /// stack, not a page in it — the page under it never leaves the window,
    /// so Back is one fade over it as it is (a pushed page's below is taken
    /// out of the window and put back: laid out and drawn again, ~120 ms).
    /// The layer has its own stack for the pages opened from Details.
    @State private var detailLayers: [Int: DetailLayer] = [:]

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
    /// First launch, nobody signed in — the welcome screen sits in front of
    /// everything, including the profile gate.
    @State private var showWelcome = false
    @State private var selectedTab = 0
    /// When Home last popped back from a pushed screen — used to swallow the
    /// stray Menu that otherwise opens the sidebar right after backing out.
    @State private var lastHomePopAt: Date?
    /// The billboard's trailer on its picture: the top bar moves out.

    @ObservedObject private var launch = LaunchPreloader.shared

    var body: some View {
        content
            // While the stage is up, nothing under it takes focus — nor
            // under the launch screen.
            .disabled(stage.scene != nil || launch.curtain)
            // THE LAUNCH (docs/LOADING-PLAN.md §4): over everything on a cold
            // start while the closest things get ready; Home is built under
            // it.
            .overlay { LaunchCurtain() }
            .animation(.easeOut(duration: 0.35), value: launch.curtain)
            .task {
                launch.run(home: homeViewModel, addonManager: addonManager, progress: progressStore,
                           homeSettings: homeCatalogSettings, tmdb: tmdbSettings)
            }
            // The welcome screen up: it covers it — no curtain on top (the
            // preload carries on behind). The profile gate is on the curtain.
            .onChange(of: showWelcome) { _, on in if on { launch.skip() } }
            // The way into the player, over everything (`PlayStage`): the
            // player's cover is clear until its first frame, so this stays
            // under it, and holds focus until then. Back cancels; the list
            // plays what's picked.
            .overlay {
                if let scene = stage.scene {
                    PlayStageView(scene: scene, onBack: {
                        PlayLauncher.shared.cancel()
                        // A link already loading goes too, or it would come up later.
                        setPlayback(nil)
                        playerClosed()
                    }) { request in sources(request) }
                    // In: its own fade (`PlayStageView.shownIn`).
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .animation(Motion.fade, value: stage.scene != nil)
            // The stage gone: focus leaves it a moment later (its fade off),
            // and the top bar took it before the rows could (`returnFocus`).
            .onChange(of: stage.scene == nil) { _, gone in
                if gone { TopBar.shared.settle(for: Self.stageSettle) }
            }
            .onOpenURL { handleDeepLink($0) }
            .onAppear {
                NSLog("[CuePlayer] RootView content onAppear")
                FocusTrace.installIfRequested()
                startPlayerDemoIfRequested()
                startDetailDemoIfRequested()
                PlayLauncher.shared.configure(.init(
                    addonManager: addonManager, progress: progressStore, watched: watched,
                    start: { meta, video, entry, all, fromStart in
                        play(meta, video, entry, all, fromStart: fromStart)
                    }))
                TitleMenu.shared.configure(library: library, watched: watched, progress: progressStore,
                                           addonManager: addonManager)
                TitleMenu.shared.openDiscover = { discoverLike($0) }
                TitleRecords.shared.watched = watched
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
                        playerSettings: playerSettings,
                        tmdbSettings: tmdbSettings
                    )
                    sync = nuvioSync
                    LaunchPreloader.shared.sync = nuvioSync
                    // Everything personal rescopes on a switch, even when
                    // signed out of Cue (the sync manager only runs while
                    // signed in): add-ons (honouring the
                    // profile's use-primary fallbacks), player
                    // settings, TMDB, theme — upstream Nuvio's
                    // per-profile boundary, ported wholesale.
                    profiles.onSwitchLocal = { [weak addonManager,
                                                weak playerSettings,
                                                weak tmdbSettings,
                                                weak searchViewModel, weak profiles] id in
                        let flags = profiles?.profiles.first { $0.id == id }
                        addonManager?.setProfile(flags?.usesPrimaryAddons == true ? 1 : id)
                        playerSettings?.setProfile(id)
                        tmdbSettings?.setProfile(id)
                        searchViewModel?.setProfile(id)
                        // Home's rows and billboard picks for this profile.
                        homeViewModel.profileSwitched()
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
                                                   weak tmdbSettings,
                                                   weak searchViewModel, weak nuvioSync] id in
                        addonManager?.forgetProfile(id)
                        playerSettings?.forgetProfile(id)
                        tmdbSettings?.forgetProfile(id)
                        searchViewModel?.forgetProfile(id)
                        nuvioSync?.syncProfilesNow()
                        SyncCoordinator.shared.requestFullSync("profile deleted")
                    }
                    // Anything sync-relevant that happens locally now kicks a
                    // full sync of every destination, debounced (see
                    // SyncCoordinator). Registered by name, so this is safe to
                    // reach twice.
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
                    let demoMode = Self.demoMode
                    // -welcomeDemo forces it regardless of the completed flag
                    // or an already-restored session, which is the only way to
                    // look at this screen twice on one install.
                    let forceWelcome = args.contains("-welcomeDemo")
                        || args.contains("-welcomeOfferDemo")
                    showWelcome = (forceWelcome || OnboardingState.shouldShow(
                        signedIn: account.authState.isSignedIn)) && !demoMode
                    // "Who's watching?" on the launch curtain.
                    launch.onGateClosed = { picked in afterProfileGate(picked: picked) }
                    if !showWelcome, !demoMode { launch.showGate(.launch) } else { launch.noGate() }
                    if args.contains("-settingsDemo") { selectedTab = 3 }
                    // Settings TAB (in-place, not the full-screen pane demo) —
                    // used to drive the ATV theme's settings in the sim.
                    if args.contains("-settingsTabDemo") { selectedTab = 3 }
                    if args.contains("-searchDemo") { selectedTab = 1 }
                    if args.contains("-libraryDemo") { selectedTab = 2 }
                    // A browse page (genre, tag, studio, network, person),
                    // opened from Home: `-browseDemo <kind> <tmdb id> <name>`.
                    if let flag = args.firstIndex(of: "-browseDemo"), flag + 3 < args.count,
                       let id = Int(args[flag + 2]) {
                        let name = args[flag + 3]
                        let route: Route? = switch args[flag + 1] {
                        case "person": .browse(.init(kind: .person, id: id, name: name))
                        case "genre": .genre(id: id, name: name, isMovie: true)
                        case "keyword": .keyword(id: id, name: name, isMovie: true)
                        case "company": .browse(.init(kind: .company, id: id, name: name))
                        case "network": .browse(.init(kind: .network, id: id, name: name))
                        default: nil
                        }
                        if let route {
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                PageFade.shared.push(key: route, background: route.pageBackground) { homePath.append(route) }
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
                            TopBar.shared.focus(AppTab.home.rawValue)
                        }
                    }
                    // Dev: jump straight to the profile gate.
                    // As opened from the top bar's avatar (with Edit).
                    if args.contains("-profileGateDemo") {
                        launch.showGate(.topBar)
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
            // On a fresh install, before the gate: "who's watching" makes no
            // sense before "who are you" — the gate comes after it, when the
            // account has profiles to choose from.
            .fullScreenCover(isPresented: $showWelcome) {
                WelcomeView(account: account, addonManager: addonManager) {
                    OnboardingState.completed = true
                    showWelcome = false
                    launch.showGate(.resume)
                }

            }
            // Returning to the app pulls the latest Continue Watching so changes
            // made on another device show up without a relaunch (local edits
            // already push immediately on every change).
            .onChange(of: scenePhase) { old, phase in
                AppProbe.scene = "\(phase)"
                AppProbe.life("scene → \(phase)")
                // Coming back after hours away: who's watching, again. From
                // the first phase out of the background, so it's there as
                // the app shows.
                if phase == .background { launch.wentAway() }
                if old == .background, phase != .background {
                    launch.cameBack(needed: playback == nil && !showWelcome)
                }
                if phase == .active {
                    // Opening the app syncs the whole account (at most
                    // every 2 min; a cycle already running is reused).
                    sync?.syncOnAppOpen(reason: "app opened")
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
    }

    private static var playerDemoStarted = false

    /// Dev-only: `-playerDemo` opens the player with Apple's public HLS test
    /// stream (`-playerDemoMKV` uses an MKV sample to exercise the FFmpeg
    /// engine) so playback UI can be verified without a stream addon.
    private func startPlayerDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let wantsMKV = args.contains("-playerDemoMKV")
        guard wantsMKV || args.contains("-playerDemo") || args.contains("-playerDemoFailover")
                || args.contains("-playerDemoDead") else { return }
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
        // `-playerDemoFailover`: dead links first, then the stream;
        // `-playerDemoDead`: dead links only.
        func entry(_ url: String) -> StreamEntry {
            StreamEntry(addonName: "Demo", stream: Stream(name: url, title: url, description: nil, url: url,
                                                          infoHash: nil, behaviorHints: nil))
        }
        let good = StreamEntry(addonName: "Demo", stream: stream)
        var entries = [good]
        if args.contains("-playerDemoFailover") || args.contains("-playerDemoDead") {
            let dead = (1...4).map { entry("http://127.0.0.1:9/dead\($0).mkv") }
            entries = args.contains("-playerDemoDead") ? dead : Array(dead.prefix(3)) + [good]
        }
        startPlayback(PlaybackRequest(
            meta: meta, video: nil, entry: entries[0],
            allEntries: entries, resumePosition: nil, isDemo: true
        ))
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
            // `-detailID tt…`: that series instead (e.g. a long one to profile)
            // — with `-detailMovie`, that film.
            let picked = args.firstIndex(of: "-detailID").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            if let picked {
                let type = args.contains("-detailMovie") ? "movie" : "series"
                return AnyView(ZStack {
                    CuePalette.background.ignoresSafeArea()
                    DetailView(item: MetaItem(id: picked, type: type, name: picked))
                })
            }
            return AnyView(
                ZStack {
                    CuePalette.background.ignoresSafeArea()
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
        // Settings → Developer → Frame Rate: a window of its own above everything.
        .onChange(of: perf.settings.frameRate, initial: true) { _, mode in FrameRateOverlay.shared.apply(mode) }
        // App-wide toast (Fusion): Added to Library / Marked Watched / etc.
        .overlay { FusionToastHost() }
        // Playing: no billboard trailer under it.
        .onChange(of: playback == nil && stage.scene == nil) { _, none in TrailerGate.shared.playerUp = !none }
        .onChange(of: playback == nil) { _, none in if none { playerClosed() } }
        .onChange(of: launch.gate != nil || showWelcome, initial: true) { _, up in TrailerGate.shared.coverUp = up }
        .fullScreenCover(item: $playback) { request in
            CuePlayer(request: request, progress: progressStore, settings: playerSettings.settings,
                      onShown: { sourcePicker.close() },
                      onClose: { setPlayback(nil) })
                .ignoresSafeArea()
                // Dark in both appearances: SwiftUI's scheme reaches the
                // controller past its own `overrideUserInterfaceStyle`.
                .environment(\.colorScheme, .dark)
                .presentationBackground(.clear)
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
        case 0: return homePath.isEmpty && detailLayers[0]?.leaving != false
        case 1: return searchPath.isEmpty
        case 2: return libraryPath.isEmpty
        case 6: return discoverPath.isEmpty
        case 7: return upcomingPath.isEmpty
        default: return true   // Settings keeps the rail
        }
    }

    /// A Back right after a pop: tvOS sometimes delivers the pop's Back a
    /// second time, within a frame or two — a real second press comes later.
    private static let popEchoWindow: TimeInterval = 0.25
    /// The top bar off while the stage goes, so focus returns to the rows.
    static let stageSettle: Double = 0.5

    private var showSidebar: Bool { !sidebarMovedOut }
    /// Out with the page's parts: off a tab's root.
    private var sidebarMovedOut: Bool { !atTabRoot }
    /// The app's single root: the top navigation floating over full-bleed
    /// content. OVERLAY layout, so the bar just draws over the content.
    private var tabLayout: some View {
        ZStack(alignment: .top) {
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Tab changes: the new page there at once (`switchTab`).
                // (No `.id(selectedTab)`: it rebuilt each tab on every
                // switch — below 10 fps. Tabs stay alive; `selectedContent`.)
                .animation(nil, value: selectedTab)
                .focusSection()
                // Up that found nothing (a disabled moment, or nothing above
                // in reach): the top bar, as Back would (its focus guide
                // catches the rest).
                .onReceive(NotificationCenter.default.publisher(
                    for: UIFocusSystem.movementDidFailNotification)) { note in
                    guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                            as? UIFocusUpdateContext, ctx.focusHeading.contains(.up),
                          TopBar.shared.focused == nil, atTabRoot, !TopBarLock.shared.locked,
                          playback == nil, launch.gate == nil, !showWelcome else { return }
                    TopBar.shared.focus(selectedTab)
                }

            // The top bar (`TopBar`): UIKit, focus and drawing; on Home,
            // Discover and Upcoming it goes up with the page (`TopBarFollow`).
            // Off a tab's root it's out of the way at once.
            TopBarView(profiles: profiles, profile: profiles.active, selected: selectedTab,
                       hidden: !atTabRoot,
                       blocked: stage.scene != nil || launch.curtain || launch.gate != nil
                           || showWelcome || playback != nil,
                       follows: AppTab(rawValue: selectedTab).flatMap {
                           $0 == .home ? "home" : $0 == .discover ? "discover" : $0 == .upcoming ? "upcoming" : nil
                       },
                       onSwitch: { switchTab(to: $0) },
                       onProfile: { launch.showGate(.topBar) })
                // Nothing of it in SwiftUI's way: a hit-testable view over
                // the page keeps SwiftUI's focus from what's under it.
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .task { await TopBar.shared.start() }
        }
        .animation(perf.motionOn
                   ? .spring(response: 0.34, dampingFraction: 0.86)
                   : nil, value: showSidebar)
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
                    .safeAreaPadding(.top, tab != .home && tab != .search && (showSidebar || !active)
                                     ? GlassSidebar.topBarClearance : 0)
                    // Search and Library draw no background of their own:
                    // the tab gives them one.
                    .background { if tab == .search || tab == .library { ATVBackground() } }
                    .opacity(active ? 1 : 0)
                    .accessibilityHidden(!active)
                    .zIndex(active ? 1 : 0)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            visitedTabs.insert(tab)
            // Home's pages say for themselves (`HomeUIKitView`).
        }
        // Your Rows' Open in Discover: the tab at its root with that
        // sentence, focus on its name in the bar; a person's, studio's or
        // network's row: its page pushed on the tab, focus on its titles.
        // Your Rows' Add from Discover: the tab at its root, focus on it in the bar.
        .onReceive(DiscoverPins.shared.showDiscover) {
            let discover = AppTab.discover.rawValue
            visitedTabs.insert(discover)
            discoverPath = []
            switchTab(to: discover)
            focusSidebar(discover)
        }
        .onReceive(DiscoverPins.shared.$opening.compactMap { $0 }) { pin in
            let discover = AppTab.discover.rawValue
            visitedTabs.insert(discover)
            discoverPath = []
            switchTab(to: discover)
            guard let subject = pin.subject else { return focusSidebar(discover) }
            DispatchQueue.main.async { DiscoverPins.shared.opening = nil }
            let model = DiscoverModel(picks: pin.slots, extras: [:], subject: subject)
            Task { await model.start() }
            PagePreparer.shared.open(DiscoverModel.key(subject), model) {
                pushPage(Route.browse(subject), $discoverPath)
            }
        }
        .task { await buildTabsAhead() }
    }

    /// Tabs opened so far (kept alive — see above).
    @State private var visitedTabs: Set<Int> = [AppTab.home.rawValue]
    /// The switch: the old page gone and the new one there in the same
    /// frame, no fade, no drift (as Netflix). Not animated: the focus move
    /// carries an animation. (Tried: a crossfade — heavy; the new page
    /// fading in over the old picture — dipped at its end; the billboard's
    /// paging slide — too much; Home drifting in 18 to 72 pt with its
    /// picture's edges carried on, and Search and Settings by a SwiftUI
    /// offset — stuttered.)
    private func switchTab(to new: Int) {
        AppProbe.tab = Self.tabName(new)
        // Navigating pulls the account, as NuvioTV (at most every 2 min).
        sync?.syncOnAppOpen(reason: "tab switch")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { selectedTab = new }
    }

    /// Every tab built, hidden, under the launch's curtain — while it waits
    /// on the network, one at a time — so the first visit is a switch like
    /// any other, not a build. (Built after the lift, 1.5 s apart, each
    /// first layout cost 90–160 ms as you pressed, and Settings arrived
    /// early had its title slide in.) A launch over before they're all in:
    /// the rest 1.5 s apart.
    private func buildTabsAhead() async {
        await LaunchPreloader.shared.homeOnScreen()
        for tab in AppTab.topBarOrder where !visitedTabs.contains(tab.rawValue) {
            try? await Task.sleep(for: .milliseconds(LaunchPreloader.shared.curtain ? 300 : 1500))
            guard !Task.isCancelled else { return }
            visitedTabs.insert(tab.rawValue)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab, active: Bool) -> some View {
        switch tab {
        case .search:
            NavigationStack(path: $searchPath) {
                searchRoot(active: active)
                    .onExitCommand {
                        // From the scopes or the row: onto the keyboard first.
                        if SearchBack.shared.anchor?.backToKeyboard() == true { return }
                        focusSidebar(1)
                    }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: trail($searchPath)) }
            }
            // Apple's search field and keyboard (UISearchController) ignore
            // the safe-area inset, and sat under the bar — a plain one here,
            // 20 pt more than the other pages' (the field read cramped under it).
            .padding(.top, searchPath.isEmpty ? GlassSidebar.topBarClearance + 20 : 0)
        case .library:
            NavigationStack(path: $libraryPath) {
                libraryRoot
                    .onExitCommand { focusSidebar(2) }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: trail($libraryPath)) }
            }
        case .settings:
            NavigationStack(path: $settingsPath) {
                CardSettingsRoot { focusSidebar(tab.rawValue) }
                    .ignoresSafeArea()
                    .probeScreen("Settings")
                    // A title's Details from a list (Watch Progress, Library).
                    .environment(\.settingsOpenTitle) { item in
                        openDetail(item) { settingsPath.append($0) }
                    }
                    .navigationDestination(for: Route.self) { destination(for: $0, path: trail($settingsPath)) }
            }
            .environmentObject(searchViewModel)
        case .home:
            homeStackWithLayers(path: $homePath, active: active)
        case .discover:
            NavigationStack(path: $discoverPath) {
                MadeOnce {
                    DiscoverView(onOpenInPlace: { item in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { discoverPath.append(Route.detail(item)) }
                    }, onBack: { focusSidebar(tab.rawValue) })
                }
                .equatable()
                .probeScreen("Discover")
                .navigationDestination(for: Route.self) { destination(for: $0, path: trail($discoverPath)) }
            }
        case .upcoming:
            NavigationStack(path: $upcomingPath) {
                MadeOnce {
                    UpcomingView(onOpen: { item in
                        DetailTransition.shared.open(item) {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { upcomingPath.append(Route.detail(item)) }
                        }
                    }, onBack: { focusSidebar(tab.rawValue) })
                }
                .equatable()
                .probeScreen("Upcoming")
                .navigationDestination(for: Route.self) { destination(for: $0, path: trail($upcomingPath)) }
            }
        }
    }

    /// Home in its stack, Details a layer over it.
    private func homeStackWithLayers(path: Binding<[Route]>, active: Bool) -> some View {
        let tab = AppTab.home
        let layer = detailLayers[tab.rawValue]
        let covered = layer.map { !$0.leaving } ?? false
        return ZStack {
            // Under Details: still in the window and laid out — only not
            // shown and out of the focus engine's way (inactive: its rows
            // hidden, as a tab behind — `.disabled` alone let focus slip
            // onto its first card, and Back landed there).
            homeStack(tab, path: path, active: active && !covered)
                .opacity(covered ? 0 : 1)
                .disabled(covered)
            if let layer {
                let layerPath = detailLayerPath(tab)
                NavigationStack(path: layerPath) {
                    layerRoot(layer.root, tab: tab, path: layerPath, leaving: layer.leaving)
                        // A page the trail moves down here is a new view
                        // (else the old root's state stays on screen).
                        .id(layer.root)
                        .probeScreen(layer.root.probeName) { layer.root.probeDetail }
                        .navigationDestination(for: Route.self) { destination(for: $0, path: layerPath) }
                }
                .id(layer.id)
                .opacity(layer.leaving ? 0 : 1)
                .disabled(layer.leaving)
            }
        }
    }

    /// Opens Details over a home-like tab: on its root, as its layer
    /// (`detailLayers`); deeper (a folder), pushed.
    private func openFromHome(_ route: Route, tab: AppTab, path: Binding<[Route]>) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if case .detail(let item) = route, path.wrappedValue.isEmpty {
                detailLayers[tab.rawValue] = DetailLayer(root: .detail(item))
            } else {
                path.wrappedValue.append(route)
            }
        }
    }

    /// The layer's pages, as `trail`: its root counts as the first page,
    /// so a page opened from the second makes that one the root.
    private func detailLayerPath(_ tab: AppTab) -> Binding<[Route]> {
        Binding(get: { detailLayers[tab.rawValue]?.path ?? [] }, set: { new in
            guard var layer = detailLayers[tab.rawValue] else { return }
            let old = layer.path
            if let added = new.last, added.isTrailPage, new.count == old.count + 1,
               Array(new.dropLast()) == old, let kept = old.last {
                Self.leave([layer.root] + old.dropLast(), kept: kept, keepStill: false)
                layer.root = kept
                layer.path = [added]
            } else {
                layer.path = new
            }
            detailLayers[tab.rawValue] = layer
        })
    }

    /// The layer's first page: Details, or a browse page the trail left
    /// there; Back from it fades the layer off the page under it.
    @ViewBuilder
    private func layerRoot(_ root: Route, tab: AppTab, path: Binding<[Route]>, leaving: Bool) -> some View {
        if case .detail(let item) = root {
            detailView(item, path: path, leaving: leaving) { closeDetailLayer(tab) }
        } else {
            destinationBody(for: root, path: path)
                .environment(\.pageBack) { closeDetailLayer(tab) }
        }
    }

    /// Back from the layer's first page: it fades off the page under it.
    private func closeDetailLayer(_ tab: AppTab) {
        guard let id = detailLayers[tab.rawValue]?.id else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        let close = {
            withTransaction(instant) { detailLayers[tab.rawValue]?.leaving = true }
            // As after a pop: focus lands on the page, not the rail.
            lastHomePopAt = Date()
            TopBar.shared.settle(for: TopBar.settleTime)
        }
        // Hidden by then; taken down once the remote is still (it holds
        // the main thread ~0.3 s: done as the move landed, a press just
        // after it came late). A Details opened meanwhile replaces it.
        let gone = {
            InputHold.whenIdle {
                guard detailLayers[tab.rawValue]?.id == id else { return }
                withTransaction(instant) { detailLayers[tab.rawValue] = nil }
            }
        }
        if case .detail(let item) = detailLayers[tab.rawValue]?.root {
            DetailTransition.shared.closeLayer(itemID: item.id, close: close, gone: gone)
        } else {
            PageFade.shared.fadeOff(close, gone: gone)
        }
    }

    /// Back is never more than two presses from where you started (a
    /// tab's own page): above it only the page on screen and
    /// the one it came from — opening another, the older ones go. (Deep
    /// in Details — a similar title, a voice actor, a genre… — Back took
    /// as many presses home.)
    private func trail(_ path: Binding<[Route]>) -> Binding<[Route]> {
        Binding(get: { path.wrappedValue }, set: { new in
            let old = path.wrappedValue
            let pages = old[...]
            guard let added = new.last, added.isTrailPage, new.count == old.count + 1,
                  Array(new.dropLast()) == old, pages.count >= 2, let kept = pages.last else {
                path.wrappedValue = new
                return
            }
            Self.leave(Array(pages.dropLast()), kept: kept, keepStill: true)
            path.wrappedValue = [kept, added]
        })
    }

    /// Pages taken off the trail under the one on screen: gone as if
    /// closed. `kept`, now first above where you started, takes the first
    /// one's still — that page (`keepStill`; a layer's root has none: its
    /// Back fades off the live page).
    private static func leave(_ dropped: [Route], kept: Route, keepStill: Bool) {
        PageFade.shared.reroot(kept.fadeKey, from: keepStill ? dropped.first?.fadeKey : nil)
        for route in dropped {
            if case .detail(let item) = route {
                DetailTransition.shared.dropped(itemID: item.id)
            } else {
                PageFade.shared.drop(route.fadeKey)
            }
        }
    }

    private func homeStack(_ tab: AppTab, path: Binding<[Route]>, active: Bool) -> some View {
        NavigationStack(path: path) {
            homeRoot(tab, path: path, active: active)
                .onExitCommand {
                    // Handing over to Details: this Back is Details' (it
                    // takes the swap straight back).
                    if modeSwap.handingOver { modeSwap.heldPress = .back; return }
                    // Ignore a Menu that lands right after popping back from
                    // a pushed screen — tvOS sometimes delivers a lingering
                    // second Menu, which would spuriously open the rail.
                    if let popped = lastHomePopAt, Date().timeIntervalSince(popped) < Self.popEchoWindow { return }
                    // Focus to the top bar; below the billboard the page goes
                    // up to it on the way (focus never on its buttons).
                    HomeBack.shared.handle { focusSidebar(tab.rawValue) }
                }
                .onChange(of: path.wrappedValue.count) { oldCount, newCount in
                    // Only a pop that lands ON the page matters here.
                    guard newCount < oldCount, newCount == 0 else { return }
                    lastHomePopAt = Date()
                    // Popping all the way back: keep the rail non-focusable
                    // for a beat so focus lands on a card instead of the rail
                    // springing open.
                    TopBar.shared.settle(for: TopBar.settleTime)
                }
                .navigationDestination(for: Route.self) { destination(for: $0, path: trail(path)) }
        }
    }

    /// Rail tabs by name, for the probe. Numbers in a log are a second thing
    /// to decode while reading a focus bug.
    static func tabName(_ tab: Int) -> String {
        AppTab(rawValue: tab)?.label ?? "Home"
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

    /// Focus to the top bar on `tab` (Back on a tab's page, the gate
    /// closed from the avatar).
    private func focusSidebar(_ tab: Int) {
        TopBar.shared.focus(tab)
    }

    /// Launched into a screen to look at: no gate covering it.
    static var demoMode: Bool {
        let args = ProcessInfo.processInfo.arguments
        return ["-detailDemo", "-detailDemoSeries", "-homeDemo", "-settingsDemo", "-searchDemo", "-libraryDemo",
                "-discoverDemo", "-accountDemo", "-settingsTabDemo", "-settingsPage",
                "-playerDemo", "-playerDemoMKV", "-playerDemoFailover", "-playerDemoDead"].contains { args.contains($0) }
    }

    /// The gate gone. A profile picked: focus to Home's billboard (its first
    /// button), the top bar settling first (it would take the first focus).
    /// Closed with Back (opened from the top bar): focus back on the avatar.
    private func afterProfileGate(picked: Bool) {
        guard picked else {
            focusSidebar(-1)
            return
        }
        TopBar.shared.settle(for: TopBar.settleTime)
        if selectedTab == 0 { HomeBack.shared.toBillboard?() }
    }

    // MARK: - Tab roots

    private func homeRoot(_ tab: AppTab, path: Binding<[Route]>, active: Bool) -> some View {
        return HomeView(
            viewModel: homeViewModel,
            active: active,
            onSelect: { openDetail($0) { openFromHome($0, tab: tab, path: path) } },
            // From the billboard (`DetailTransition` already running).
            onSelectFeatured: { openFromHome(Route.detail($0), tab: tab, path: path) },
            onResume: { resume($0) },
            onStartOver: { resume($0, fromBeginning: true) },
            onChooseSource: { playManuallyFromProgress($0) },
            onContentReady: {
                // Give the freshly-loaded rows a beat to render and take
                // initial focus before the rail becomes focusable. This must
                // ONLY schedule the re-enable — it fires on every catalog
                // refresh, and disabling first would kick focus off an OPEN
                // rail whenever a background sync reloaded Home.
                TopBar.shared.enable(after: 0.8)
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

    /// Details pushed without the system's slide (a title's zoom brings it in).
    private func openInPlace(_ path: Binding<[Route]>) -> (MetaItem) -> Void {
        { item in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { path.wrappedValue.append(Route.detail(item)) }
        }
    }

    private func searchRoot(active: Bool) -> some View {
        SearchView(
            viewModel: searchViewModel,
            active: active,
            onOpenInPlace: { item in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { searchPath.append(Route.detail(item)) }
            },
            onOpenPerson: { id, name in
                browse(.init(kind: .person, id: id, name: name), backdrop: nil, $searchPath)
            },
            onOpenStudio: { id, name in
                browse(.init(kind: .company, id: id, name: name), backdrop: nil, $searchPath)
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
    private func destination(for route: Route, path: Binding<[Route]>) -> some View {
        destinationBody(for: route, path: path)
            .environment(\.pageBack) {
                PageFade.shared.back(key: route) {
                    if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                }
            }
            .probeScreen(route.probeName) { route.probeDetail }
            // The trail moves pages down the stack: each keeps its own view
            // (by place, the page first in line kept the dropped one's).
            .id(route)
    }

    /// A card's Discover: the title's words (`DiscoverModel.like`; only
    /// films or shows where TMDB doesn't know it), pushed on the tab
    /// showing, over its Details where that's up.
    private func discoverLike(_ item: MetaItem) {
        let settled = ContinuousClock.now + .seconds(HoldMenu.settle)
        Task { @MainActor in
            var picks: [DiscoverModel.Slot: String] = [.type: item.isSeries ? "shows" : "movies"]
            if let (id, isMovie) = await TMDBService.resolveTMDBID(from: item.id, type: item.type),
               let traits = await TMDBService.traits(tmdbID: id, isMovie: isMovie) {
                picks = DiscoverModel.like(traits, isMovie: isMovie)
            }
            // Picked from the hold menu: in once it's gone (`HoldMenu.settle`).
            try? await Task.sleep(until: settled, clock: .continuous)
            let path: Binding<[Route]>
            switch AppTab(rawValue: selectedTab) {
            case .home:
                path = detailLayers[AppTab.home.rawValue].map { !$0.leaving } == true
                    ? detailLayerPath(.home) : trail($homePath)
            case .search: path = trail($searchPath)
            case .library: path = trail($libraryPath)
            case .discover: path = trail($discoverPath)
            case .upcoming: path = trail($upcomingPath)
            default: return
            }
            pushPage(Route.discover(name: item.name,
                                    picks: Dictionary(uniqueKeysWithValues: picks.map { ($0.key.rawValue, $0.value) }),
                                    backdrop: item.background ?? item.poster), path)
        }
    }

    /// A person's, studio's or network's page: its titles start at the
    /// press, the page in once they are (`PagePreparer`).
    private func browse(_ subject: DiscoverModel.Subject, backdrop: String?, _ path: Binding<[Route]>) {
        DiscoverModel.open(subject) { pushPage(Route.browse(subject, backdrop: backdrop), path) }
    }

    /// A page (a browse page) in: `PageFade`'s crossfade, no slide.
    private func pushPage(_ route: Route, _ path: Binding<[Route]>) {
        PageFade.shared.push(key: route, background: route.pageBackground) { path.wrappedValue.append(route) }
    }

    /// Details, its pages pushed on `path`.
    private func detailView(_ item: MetaItem, path: Binding<[Route]>, leaving: Bool = false,
                            onBack: @escaping () -> Void) -> some View {
        DetailView(
            item: item,
            onSelectItem: { openDetail($0) { path.wrappedValue.append($0) } },
            onSelectPerson: { id, name, backdrop in
                browse(.init(kind: .person, id: id, name: name), backdrop: backdrop, path)
            },
            onSelectCompany: { company, backdrop in
                browse(.init(kind: company.isNetwork ? .network : .company, id: company.id, name: company.name),
                       backdrop: backdrop, path)
            },
            onSelectGenre: { genre, isMovie, backdrop in
                pushPage(Route.genre(id: genre.id, name: genre.name, isMovie: isMovie, backdrop: backdrop), path)
            },
            onSelectKeyword: { keyword, isMovie, backdrop in
                pushPage(Route.keyword(id: keyword.id, name: keyword.name, isMovie: isMovie,
                                       backdrop: backdrop), path)
            },
            onReturnToBillboard: onBack,
            takesPrepared: !leaving
        )
    }

    @ViewBuilder
    private func destinationBody(for route: Route, path: Binding<[Route]>) -> some View {
        switch route {
        case .detail(let item):
            // Back: `DetailTransition` (the simple exit) — no system slide.
            detailView(item, path: path) {
                DetailTransition.shared.close(itemID: item.id) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
                    }
                }
            }
        case .browse(let subject, let backdrop):
            DiscoverView(DiscoverModel.prepared(subject), backdrop: backdrop, onOpenInPlace: openInPlace(path),
                         onOpenSubject: { browse($0, backdrop: backdrop, path) })
        // Discover, filled in.
        case .genre(let id, let name, let isMovie, let backdrop):
            DiscoverView(DiscoverModel.genre(id: id, name: name, isMovie: isMovie), backdrop: backdrop,
                         onOpenInPlace: openInPlace(path))
        case .keyword(let id, let name, let isMovie, let backdrop):
            DiscoverView(DiscoverModel.keyword(id: id, name: name, isMovie: isMovie), backdrop: backdrop,
                         onOpenInPlace: openInPlace(path))
        case .discover(_, let picks, let backdrop):
            DiscoverView(DiscoverModel(picks: Dictionary(uniqueKeysWithValues: picks.compactMap { key, value in
                DiscoverModel.Slot(rawValue: key).map { ($0, value) }
            }), extras: [:]), backdrop: backdrop, onOpenInPlace: openInPlace(path))
        }
    }

    /// Plays a picked link — from its saved position, or from the start.
    private func play(_ meta: MetaItem, _ video: MetaVideo?, _ entry: StreamEntry, _ all: [StreamEntry],
                      fromStart: Bool) {
        let key = ProgressStore.key(metaID: meta.id, video: video)
        startPlayback(PlaybackRequest(meta: meta, video: video, entry: entry, allEntries: all,
                                      resumePosition: fromStart ? nil : progressStore.progress(for: key)?.positionSeconds))
    }

    /// In and out at once: the fades are the stage's and the player's own.
    private func startPlayback(_ request: PlaybackRequest) {
        PlayStage.shared.show(request.meta, request.video)
        setPlayback(request)
    }

    private func setPlayback(_ request: PlaybackRequest?) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { playback = request }
    }

    /// Before its first frame the stage is still under the player: Back from
    /// a picked link lands on the list, else it goes.
    private func playerClosed() {
        if sourcePicker.request != nil { sourcePicker.picked = false } else { stage.clear() }
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

    /// Continue Watching's Select and Start Over: into the stage as into
    /// Details (`DetailTransition.openStage`). The stored row canonicalized
    /// first (`tmdb:` ids to IMDb's: Cinemeta and Torrentio only speak `tt`).
    private func resume(_ progress: WatchProgress, fromBeginning: Bool = false) {
        DetailTransition.shared.openStage(ContinueActions.title(progress)) { picture in
            let (meta, video) = await canonicalResumeIdentity(progress)
            await Self.stageReady(meta)
            // Always a fresh link, the first one, as Play: a remembered URL expires.
            PlayLauncher.shared.play(meta, video, fromStart: fromBeginning, art: picture, bands: picture,
                                     grown: true)
        }
    }

    /// What the stage draws over the card decoded before it's shown under
    /// the cover (its logo), so its parts appear whole.
    private static func stageReady(_ meta: MetaItem) async {
        guard let logo = meta.logo ?? BillboardPicks.metaHubLogo(meta.id) else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await ImageCache.shared.preload(logo, maxDimension: PictureSize.logo) }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The source list on the stage.
    private func sources(_ request: SourcePicker.Request) -> some View {
        SourcePanel(meta: request.meta, video: request.video,
                    onPlay: { entry, all in
            sourcePicker.picked = true
            stage.note = nil
            play(request.meta, request.video, entry, all, fromStart: request.fromStart)
        }, onClose: { sourcePicker.back() })
        .id(request.id)
        .ignoresSafeArea()
    }

    /// Continue Watching hold → "Choose Source": the source picker, through
    /// the SAME identity repair as a resume (`tmdb:` metaIDs, rows typed "tv",
    /// synced rows missing season/episode) — the raw stored row found no
    /// sources.
    private func playManuallyFromProgress(_ progress: WatchProgress) {
        // Into the stage as into Details; Back fades off.
        DetailTransition.shared.openStage(ContinueActions.title(progress)) { picture in
            let (meta, video) = await canonicalResumeIdentity(progress)
            await Self.stageReady(meta)
            SourcePicker.shared.open(meta, video, art: picture, bands: picture, grown: true)
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

/// THE LAUNCH: on a cold start, under the launch curtain (the app's background,
/// as the launch screen, and a line saying what's under way — `status`),
/// Home gets ready: its saved rows, then the minimum — every catalog fresh
/// and the Nuvio pull, the billboard's picks from those, what the first
/// screen draws and one press reaches (`minimumJobs`) — and Home is built
/// under it. Then the rest of Home, nearest first (`deep`, `LoadQueue`),
/// until `minimum` has passed; it goes on behind Home. The curtain waits
/// for the minimum however long it takes, up to `ceiling`. Then the
/// curtain fades into Home; input
/// comes back with the fade (`lift`). Every step logs a count and its time to
/// the probe.
/// "Who's watching?" (`ProfileGate`) is the curtain from its first frame,
/// one profile or more (a choice always: Add Profile is there): the preload
/// runs under it for the last profile (focus starts there, picked by itself
/// after a rest); another one picked, the same steps again for it
/// (`restart`); not ready, its avatar waits in the middle over the status
/// line; ready, it flies to the top bar as Home dissolves in (`gateLanded`). The same gate after 4 hours
/// away (`resume`) and from the top bar's avatar (`topBar`, Back closes it).
@MainActor
final class LaunchPreloader: ObservableObject {
    static let shared = LaunchPreloader()

    /// Over the app, input off — until everything's ready (or the gate has
    /// landed).
    @Published private(set) var curtain = true
    /// Under the picked avatar while Home gets ready (`ProfileGate`), the
    /// stage's style (`SweepLine`): one line, a hint, not the steps (they
    /// go to the probe) — one of `lines` per launch, never changing
    /// mid-wait.
    @Published private(set) var status = LaunchPreloader.lines[0]
    static let lines = ["Assembling the lineup", "Gathering the cast", "Aligning the satellites"]

    enum GateMode { case launch, resume, topBar }
    /// "Who's watching?" on the curtain.
    @Published private(set) var gate: GateMode?
    /// Home is ready for the active profile (the preload done) — the gate's
    /// picked avatar flies once it is.
    @Published private(set) var ready = false
    /// The gate closed: true when a profile was picked (focus to the
    /// billboard), false when Back closed it (focus back on the avatar).
    var onGateClosed: (Bool) -> Void = { _ in }

    /// Up at least this long, the time past the minimum spent going deeper
    /// (`deep`): a fast launch gets more ready, not a flash.
    static let minimum: Double = 3
    /// The safety ceiling: the curtain waits for the minimum however long
    /// it takes — only a broken network gets here; then placeholders.
    static let ceiling: Double = 15
    /// The account's sync (Continue Watching, library), waited for at launch.
    weak var sync: NuvioSyncManager?
    /// Away this long, the gate asks again.
    static let awayForGate: TimeInterval = 4 * 60 * 60

    private var started = false
    private var finished = false
    private var stepsStarted = CACurrentMediaTime()
    private let launchedAt = Date()

    /// The launch's account pull done (or none to wait for): Home's rows
    /// decide whether they're due only then — decided before it, a due
    /// build ran on the history not yet in ("taste from 1 titles") and the
    /// rows stayed that way. 10 s at most.
    func historySettled() async {
        let begun = CACurrentMediaTime()
        var sawSyncing = false
        while CACurrentMediaTime() - begun < 10 {
            if let sync {
                guard sync.signedIn else { return }
                if let at = sync.lastSyncedAt, at >= launchedAt { return }
                if sync.isSyncing { sawSyncing = true } else if sawSyncing { return }
            } else if CACurrentMediaTime() - begun > 3 {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    private var elapsed: Double { CACurrentMediaTime() - stepsStarted }
    private weak var home: HomeViewModel?
    private weak var addonManager: AddonManager?
    private weak var progress: ProgressStore?
    private weak var homeSettings: HomeCatalogSettingsStore?
    private weak var tmdb: TMDBSettingsStore?
    private var generation = 0
    private var wentAwayAt: Date?

    func run(home: HomeViewModel, addonManager: AddonManager, progress: ProgressStore,
             homeSettings: HomeCatalogSettingsStore, tmdb: TMDBSettingsStore) {
        guard !started else { return }
        started = true
        self.home = home
        self.addonManager = addonManager
        self.progress = progress
        self.homeSettings = homeSettings
        self.tmdb = tmdb
        start(firstLaunch: true)
    }

    private func start(firstLaunch: Bool) {
        generation &+= 1
        let current = generation
        finished = false
        ready = false
        status = Self.lines.randomElement() ?? Self.lines[0]
        stepsStarted = CACurrentMediaTime()
        Task { await steps(firstLaunch: firstLaunch, generation: current) }
        Task {
            try? await Task.sleep(for: .seconds(Self.ceiling))
            if current == generation { finish(note: "ceiling reached") }
        }
    }

    /// Covered by the welcome screen: the curtain just goes.
    func skip() {
        finish(note: "covered")
        lift()
    }

    private func finish(note: String) {
        guard !finished else { return }
        finished = true
        line(String(format: "Total     %.2f s  (%@)", elapsed, note))
        ready = true
        if gate == nil { lift() }
    }

    /// Returns once the curtain has lifted (at once if it has), or the
    /// task is cancelled — a cancelled task's sleep returns at once, so the
    /// loop spun at full speed for as long as the curtain stayed (the gate).
    func lifted() async {
        while curtain, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Home's saved rows drawn under the curtain: from here the launch
    /// mostly waits on the network, the main thread nearly idle — the
    /// other tabs are built then (`buildTabsAhead`).
    private var homeDrawn = false
    func homeOnScreen() async {
        while !homeDrawn, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// The curtain fades into Home and input comes back.
    func lift() {
        guard curtain else { return }
        curtain = false
        // The focus engine doesn't pick a focus by itself — the first press
        // only woke it. Asked to, once the page is enabled.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            window?.rootViewController?.setNeedsFocusUpdate()
            window?.rootViewController?.updateFocusIfNeeded()
            if let speed = Self.slowMotion { window?.layer.speed = speed }
        }
    }

    /// Dev: `-slowMo [speed]` — every Core Animation and UIKit animation in
    /// the app at that speed (0.1 by default) once the curtain lifts, to
    /// watch one. Timers keep real time.
    static let slowMotion: Float? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-slowMo") else { return nil }
        return arguments.dropFirst(at + 1).first.flatMap(Float.init) ?? 0.1
    }()

    // MARK: The gate

    /// Until the root has decided (its first appearance), the curtain shows
    /// the gate it expects — the gate from the first frame, no play before it.
    @Published private(set) var gateDecided = false
    func noGate() { gateDecided = true }

    /// "Who's watching?" over the app. At launch the preload carries on
    /// under it; coming back or from the top bar Home is already there.
    func showGate(_ mode: GateMode) {
        gateDecided = true
        guard gate == nil else { return }
        gate = mode
        curtain = true
        if mode != .launch {
            ready = true
        }
    }

    /// A profile picked at the gate. Another one than before: the stores
    /// have switched (`setActive`) — its Home gets ready the launch's way,
    /// counted from the pick.
    func picked(switched: Bool) {
        guard switched else { return }
        line("Switch    profile picked at the gate")
        start(firstLaunch: false)
    }

    /// The picked avatar has landed on the top bar: the gate is gone.
    func gateLanded() {
        gate = nil
        lift()
        onGateClosed(true)
    }

    /// Back at the gate opened from the top bar.
    func cancelGate() {
        guard gate == .topBar else { return }
        gate = nil
        lift()
        onGateClosed(false)
    }

    /// The app went to the background / came back: after `awayForGate`,
    /// the gate (if there is one to show — `needed`), at once (the system's
    /// play goes at once: the app's frame is ready). Back to the page: the
    /// page as it was.
    func wentAway() { wentAwayAt = Date() }
    func cameBack(needed: Bool) {
        defer { wentAwayAt = nil }
        if !curtain { deep() }
        guard let away = wentAwayAt else { return }
        let gateDue = needed && gate == nil && !curtain
            && Date().timeIntervalSince(away) >= Self.awayForGate
        guard gateDue else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showGate(.resume) }
    }

    private func line(_ text: String) {
        PlayerProbe.event("launch", text)
    }

    private func steps(firstLaunch: Bool, generation current: Int) async {
        guard let home, let addonManager else { return }
        // The titles' records (`TitleRecords`): one small file, into memory.
        TitleRecords.shared.load()
        // ① From disk: Home's rows and billboard picks (Home reads its cache
        // as it's built under the curtain).
        var t = CACurrentMediaTime()
        let launchedAt = Date()
        // After a switch at the gate: the new profile's reload (`profileSwitched`)
        // — its rows and picks replace the old profile's.
        let loadedBefore = firstLaunch ? nil : home.loadedAt
        while home.entries.isEmpty, elapsed < 1.0 { try? await Task.sleep(for: .milliseconds(25)) }
        line(String(format: "Disk      rows %d · %.0f ms", home.entries.count, (CACurrentMediaTime() - t) * 1000))
        homeDrawn = true

        // ② The minimum begins with the network: Home's rows (its own load,
        // started as it was built: the saved ones, made again when due) and
        // the account's pull (Continue Watching, library — `syncOnAppOpen`),
        // so Home shows the latest and nothing changes under you after the
        // curtain.
        t = CACurrentMediaTime()
        var sawSyncing = false
        func catalogsIn() -> Bool { home.loadedAt != nil && home.loadedAt != loadedBefore }
        func syncIn() -> Bool {
            guard let sync, sync.signedIn else { return true }
            if sync.isSyncing { sawSyncing = true; return false }
            if let at = sync.lastSyncedAt, at >= launchedAt { return true }
            return sawSyncing   // ended without a success (failed, abandoned)
        }
        while current == generation {
            let catalogs = catalogsIn(), synced = syncIn()
            if catalogs, synced { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard current == generation else { return }
        line(String(format: "Network   rows and sync · %.0f ms", (CACurrentMediaTime() - t) * 1000))

        // The billboard's own picks, made from the fresh rows.
        t = CACurrentMediaTime()
        while !home.picksCurrent, current == generation { try? await Task.sleep(for: .milliseconds(25)) }
        guard current == generation else { return }
        // (Home's own: its first `BillboardPicks.count` — the model holds
        // every tab's.)
        let picks = home.billboard().map(\.item)
        let rows = home.entries
        line(String(format: "Picks     %d · %.0f ms", picks.count, (CACurrentMediaTime() - t) * 1000))

        // One-time artwork (cheap), on the main actor — under the curtain.
        _ = StageArt.shade
        _ = FixedFocusCardEdge.shadowImage

        // ③ The rest of the minimum, through the queue (`LoadQueue`): what
        // the first screen draws and one press reaches — records, pictures.
        t = CACurrentMediaTime()
        let jobs = minimumJobs(picks: picks, rows: rows, addonManager: addonManager)
        let keys = jobs.map(\.key)
        LoadQueue.shared.add(jobs)
        while LoadQueue.shared.busy(keys), current == generation {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard current == generation else { return }
        line(String(format: "Minimum   %d jobs · %.0f ms (at %.2f s)", jobs.count,
                    (CACurrentMediaTime() - t) * 1000, elapsed))
        // The first screen was drawn before its records: its badges now,
        // still under the curtain.
        NotificationCenter.default.post(name: TitleRecords.badgesSettled, object: nil)

        // ④ The rest of Home, nearest first: on the curtain until `minimum`
        // (the floor), then on behind Home.
        LoadQueue.shared.launchStartedAt = stepsStarted
        deep(force: true)
        if elapsed < Self.minimum {
            try? await Task.sleep(for: .seconds(Self.minimum - elapsed))
        }
        guard current == generation else { return }
        finish(note: "ready")
    }

    /// What the first screen draws and one press reaches: the billboard's
    /// first three titles (records, Details' data, picture, logo, colours),
    /// the first row's cards (records, posters), the first card of each of
    /// the 3 rows below in the box (its picture and logo), Continue
    /// Watching's episode stills.
    private func minimumJobs(picks: [MetaItem], rows: [HomeRow], addonManager: AddonManager) -> [LoadQueue.Job] {
        var jobs: [LoadQueue.Job] = []
        // The badges' Acclaimed and Hidden gem (from disk; the first time
        // ever, fetched).
        jobs.append(.init(key: "imdb-ratings", kind: "imdb ratings", lane: .data, band: .launch,
                          order: 0, source: "launch") { await IMDbRatings.ready() })
        func record(_ item: MetaItem) {
            jobs.append(.record(item, band: .launch, order: jobs.count, source: "launch"))
        }
        func picture(_ url: String?, _ size: CGFloat) {
            guard let url else { return }
            jobs.append(.picture(url, size, band: .launch, order: jobs.count, source: "launch"))
        }
        for item in picks.prefix(3) {
            record(item)
            picture(TMDBService.originalSize(item.background) ?? item.poster, PictureSize.screen)
            picture(item.logo, PictureSize.logo)
            if let addon = addonManager.metaAddons(for: item.type, id: item.id).first {
                jobs.append(.init(key: "meta:\(item.id)", kind: "meta", lane: .data, band: .launch,
                                  order: jobs.count, source: "launch") {
                    _ = await StremioAPI.warmMeta(addon: addon, type: item.type, id: item.id)
                })
            }
        }
        for item in (rows.first?.items ?? []).prefix(8) {
            record(item)
            picture(item.poster ?? item.background, PictureSize.poster)
        }
        for row in rows.prefix(4) {
            guard let first = row.items.first else { continue }
            record(first)
            picture(first.background ?? first.poster, PictureSize.landscape)
            picture(first.logo, PictureSize.cardLogo)
        }
        if let progress, let homeSettings {
            let watching = Array(progress.continueWatching(sortMode: homeSettings.continueWatchingSortMode).prefix(6))
            jobs.append(.init(key: "stills", kind: "stills", lane: .data, band: .launch,
                              order: jobs.count, source: "launch") {
                let stills = await ContinueStills.shared.load(watching)
                await withTaskGroup(of: Void.self) { group in
                    for url in stills {
                        group.addTask { @MainActor in
                            _ = await ImageCache.shared.preload(url, maxDimension: PictureSize.landscape)
                        }
                    }
                }
            })
        }
        return jobs
    }

    /// The rest of Home behind the minimum, nearest first (`LoadQueue`'s
    /// deep band): Details for the billboard's first title and the rows'
    /// (`TitlePreloader`, as if focus rested on the billboard), every title's
    /// record (the billboard's and every row's: the badges and ratings are
    /// drawn from them at once, never late; the ratings asked of MDBList in
    /// batches first, 200 a request, so every title has them), and
    /// their pictures (each row's first 15) on
    /// disk at the size they show at — not decoded into memory (that would
    /// evict the first screen's). At launch, and coming back once an hour
    /// has passed; only what's a day old asks the network.
    private var deepAt: Date?
    private func deep(force: Bool = false) {
        guard let home else { return }
        if !force, let deepAt, Date().timeIntervalSince(deepAt) < 60 * 60 { return }
        deepAt = Date()
        let picks = home.billboard().map(\.item)
        let rows = home.entries
        let featured = HomeRow(id: Spotlight.featuredRowID, title: "Featured", items: picks)
        TitlePreloader.shared.focused(rows: [featured] + rows, row: 0, index: 0)
        var jobs: [LoadQueue.Job] = []
        // Every title's ratings in a few batched requests: the records below
        // then find them in MDBList's cache.
        let rated = picks + rows.flatMap(\.items)
        jobs.append(.init(key: "ratings", kind: "ratings", lane: .data, band: .deep, order: -1, source: "deep") {
            await MDBListService.prefetch(rated, settings: MDBListSettingsStore.current)
        })
        for (i, item) in picks.enumerated() {
            jobs.append(.record(item, band: .deep, order: i, source: "deep"))
            if let url = TMDBService.originalSize(item.background) ?? item.poster {
                jobs.append(.disk(url, PictureSize.screen, order: i))
            }
            if let logo = item.logo { jobs.append(.disk(logo, PictureSize.logo, order: i)) }
        }
        for (r, row) in rows.enumerated() {
            for (i, item) in row.items.enumerated().dropFirst(15) {
                jobs.append(.record(item, band: .deep, order: 10_000 + r * 100 + i, source: "deep"))
            }
            for (i, item) in row.items.prefix(15).enumerated() {
                let order = (r + 1) * 100 + i
                jobs.append(.record(item, band: .deep, order: order, source: "deep"))
                if let url = item.poster ?? item.background { jobs.append(.disk(url, PictureSize.poster, order: order)) }
                // The box's picture for the first few (Left/Right's next).
                guard i < 4 else { continue }
                if let url = item.background ?? item.poster { jobs.append(.disk(url, PictureSize.landscape, order: order)) }
                if let logo = item.logo { jobs.append(.disk(logo, PictureSize.cardLogo, order: order)) }
            }
        }
        // The background's pool (`BackgroundPicks`): last, one job.
        let pool = picks + rows.flatMap { $0.items.prefix(15) }
        jobs.append(.init(key: "backgrounds", kind: "backgrounds", lane: .data, band: .deep,
                          order: Int.max, source: "deep") { await BackgroundPicks.shared.offer(pool) })
        LoadQueue.shared.replace(source: "deep", with: jobs)
    }
}

/// ONE QUEUE for what's loaded ahead — records, Details' data, pictures —
/// nearest first. Three bands: focus (what the next press reaches —
/// `PicturePreloader`, `TitleExtras`, `TitlePreloader`, each replacing its
/// own waiting jobs as focus moves), the launch's minimum, and the rest of
/// Home (`deep`). Two lanes, 3 jobs each: data (requests) and pictures
/// (decodes, under `DecodeGate`); the deep band leaves room in each for
/// focus. A key is loaded once at a time; asked again nearer, a waiting job
/// moves up. Nothing new starts outside the launch while the player is up.
/// Each kind's count and time go to the probe when it runs dry (`queue`).
@MainActor
final class LoadQueue {
    static let shared = LoadQueue()

    enum Lane { case data, picture }
    enum Band: Int { case focus, launch, deep }

    struct Job {
        let key: String
        let kind: String
        let lane: Lane
        let band: Band
        let order: Int
        let source: String
        let run: @MainActor () async -> Void

        init(key: String, kind: String, lane: Lane, band: Band, order: Int, source: String,
             run: @escaping @MainActor () async -> Void) {
            self.key = key; self.kind = kind; self.lane = lane; self.band = band
            self.order = order; self.source = source; self.run = run
        }

        /// A title's record (`TitleRecords`): its size, facts, ratings.
        static func record(_ item: MetaItem, band: Band, order: Int, source: String,
                           then: (@MainActor () -> Void)? = nil) -> Job {
            Job(key: "record:\(item.id)", kind: "record", lane: .data, band: band, order: order, source: source) {
                await TitleRecords.shared.refresh(item, [.show, .facts, .ratings])
                then?()
            }
        }

        /// Decoded into memory at `size`.
        static func picture(_ url: String, _ size: CGFloat, band: Band, order: Int, source: String,
                            still: (@MainActor () -> Bool)? = nil) -> Job {
            Job(key: "picture:\(RemoteImage.memoryKey(url, maxDimension: size, maxPixels: nil))", kind: "picture",
                lane: .picture, band: band, order: order, source: source) {
                _ = await ImageCache.shared.preload(url, maxDimension: size, turn: band == .launch ? .now : .ahead,
                                                    still: still)
            }
        }

        /// On disk at `size`, not in memory (`keepOnDisk`): the deep band.
        static func disk(_ url: String, _ size: CGFloat, order: Int) -> Job {
            Job(key: "disk:\(RemoteImage.memoryKey(url, maxDimension: size, maxPixels: nil))", kind: "disk",
                lane: .picture, band: .deep, order: order, source: "deep") {
                _ = await ImageCache.shared.keepOnDisk(url, maxDimension: size)
            }
        }
    }

    static let perLane = 3
    /// The deep band's share: one picture (decodes compete with focus's in
    /// `DecodeGate`), two requests.
    static func deepShare(_ lane: Lane) -> Int { lane == .picture ? 1 : 2 }

    private var waiting: [Job] = []
    private var keys = Set<String>()
    private var running: [Lane: Int] = [:]
    private var runningDeep: [Lane: Int] = [:]
    private var stats: [String: (count: Int, ms: Double)] = [:]
    private var playerWait: Task<Void, Never>?
    /// The launch's start, for the probe's "full Home at" line.
    var launchStartedAt: Double?

    /// Any of `keys` still waiting or running.
    func busy(_ keys: [String]) -> Bool { keys.contains { self.keys.contains($0) } }

    func add(_ jobs: [Job]) {
        for job in jobs {
            if keys.insert(job.key).inserted {
                waiting.append(job)
            } else if let at = waiting.firstIndex(where: { $0.key == job.key }),
                      (job.band.rawValue, job.order) < (waiting[at].band.rawValue, waiting[at].order) {
                waiting[at] = job   // asked nearer: up it goes
            }
        }
        unsorted = true
        pump()
    }

    /// Jobs came in since the last sort. (Sorted on every pump — after
    /// every job's end — the deep band's ~2,000 jobs held the main thread
    /// 100–200 ms at a time, stalling the rows' moves.)
    private var unsorted = false

    /// `source`'s waiting jobs replaced by `jobs` (focus has moved on).
    func replace(source: String, with jobs: [Job]) {
        // (The order stays sorted: only `add` unsorts it.)
        waiting.removeAll { job in
            guard job.source == source else { return false }
            keys.remove(job.key)
            return true
        }
        add(jobs)
    }

    private func pump() {
        let playing = PlayerController.isPlaying
        if unsorted {
            waiting.sort { ($0.band.rawValue, $0.order) < ($1.band.rawValue, $1.order) }
            unsorted = false
        }
        // Plain counts, read once (a dictionary per job, through ~2,000
        // waiting, was itself a stall).
        var data = running[.data, default: 0], picture = running[.picture, default: 0]
        var dataDeep = runningDeep[.data, default: 0], pictureDeep = runningDeep[.picture, default: 0]
        let dataShare = Self.deepShare(.data), pictureShare = Self.deepShare(.picture)
        var i = 0
        while i < waiting.count {
            let lane = waiting[i].lane, band = waiting[i].band
            if playing && band != .launch { i += 1; continue }
            // Nothing more can start: the rest wait (sorted: once in the
            // deep band, only deep jobs follow).
            let dataFree = data < Self.perLane, pictureFree = picture < Self.perLane
            if !dataFree, !pictureFree { break }
            if band == .deep, !(dataFree && dataDeep < dataShare), !(pictureFree && pictureDeep < pictureShare) { break }
            let free = lane == .data
                ? dataFree && (band != .deep || dataDeep < dataShare)
                : pictureFree && (band != .deep || pictureDeep < pictureShare)
            guard free else { i += 1; continue }
            if lane == .data { data += 1; if band == .deep { dataDeep += 1 } }
            else { picture += 1; if band == .deep { pictureDeep += 1 } }
            start(waiting.remove(at: i))
        }
        // Held for the player: looked at again every few seconds.
        if playing, !waiting.isEmpty, playerWait == nil {
            playerWait = Task { @MainActor [weak self] in
                while PlayerController.isPlaying { try? await Task.sleep(for: .seconds(5)) }
                self?.playerWait = nil
                self?.pump()
            }
        }
    }

    private func start(_ job: Job) {
        running[job.lane, default: 0] += 1
        if job.band == .deep { runningDeep[job.lane, default: 0] += 1 }
        Task { @MainActor in
            let t = CACurrentMediaTime()
            await job.run()
            running[job.lane, default: 0] -= 1
            if job.band == .deep { runningDeep[job.lane, default: 0] -= 1 }
            keys.remove(job.key)
            var entry = stats[job.kind] ?? (0, 0)
            entry.count += 1
            entry.ms += (CACurrentMediaTime() - t) * 1000
            stats[job.kind] = entry
            pump()
            if waiting.isEmpty, running.values.allSatisfy({ $0 == 0 }) { ranDry() }
        }
    }

    /// The probe: what ran since it last ran dry — each kind's count and
    /// its jobs' summed time — and when (from the launch, the first time:
    /// the full variant's cost).
    private func ranDry() {
        let summary = stats.sorted { $0.key < $1.key }
            .map { String(format: "%@ %d (%.1f s)", $0.key, $0.value.count, $0.value.ms / 1000) }
            .joined(separator: " · ")
        let at = launchStartedAt.map { String(format: " · at %.2f s from launch", CACurrentMediaTime() - $0) } ?? ""
        PlayerProbe.event("queue", "Dry       \(summary)\(at)")
        stats = [:]
        launchStartedAt = nil
    }
}

/// The launch curtain: the background and the gate on it (`ProfileGate`),
/// from the first frame tvOS gives us — the status line alone only where
/// there's no gate (the demos).
struct LaunchCurtain: View {
    @ObservedObject private var launch = LaunchPreloader.shared
    /// The gate's avatar flying to the top bar: the background dissolves
    /// off Home with it.
    @State private var dissolving = false
    /// The background is in: the gate never comes in before it (1 s more
    /// at most — a first draw, no copy on disk yet).
    @State private var backgroundIn = BackgroundStore.shared.image != nil
    /// The gate shown — or, before the root has decided, the one it will
    /// show at launch (the same view, so nothing changes as it's decided).
    private var gate: LaunchPreloader.GateMode? {
        if let gate = launch.gate { return gate }
        guard !launch.gateDecided, !RootView.demoMode else { return nil }
        return .launch
    }

    var body: some View {
        ZStack {
            if launch.curtain {
                ZStack {
                    // One background under both (two crossfading dipped).
                    ATVBackground()
                        .opacity(dissolving ? 0 : 1)
                        .animation(ProfileGate.dissolve, value: dissolving)
                        .allowsHitTesting(false)
                    if let mode = gate {
                        if backgroundIn {
                            ProfileGate(mode: mode, onFly: { dissolving = true })
                                .transition(.opacity)
                        }
                    } else {
                        SweepLine(text: launch.status, sweeping: true)
                            .frame(width: 1200, height: 44)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.fade, value: gate == nil)
                .animation(Motion.fade, value: backgroundIn)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .task {
            guard !backgroundIn else { return }
            let start = CACurrentMediaTime()
            while BackgroundStore.shared.image == nil, CACurrentMediaTime() - start < 1, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
            }
            // Its fade over, then the gate.
            try? await Task.sleep(for: .seconds(Motion.fadeDuration))
            backgroundIn = true
        }
        // Back for the next gate as the curtain comes (at once: reset as it
        // went, the background came back during the curtain's own fade).
        .onChange(of: launch.curtain) { _, on in
            guard on else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dissolving = false }
        }
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
/// What a page loads before it can show its content (`PagePreparer`).
@MainActor
protocol PreparedPage: AnyObject {
    /// Its content is in (the page can open complete).
    var isReady: Bool { get }
}

/// A page's data, loading: started at the press (`PagePreparer`) or by
/// the page itself. `value` nil: the page shows its placeholders.
@MainActor
final class PageLoad<Value>: ObservableObject, PreparedPage {
    @Published private(set) var value: Value?
    /// `value` is all of it (not only the first screen's).
    private(set) var whole = false
    private var started = false
    var isReady: Bool { value != nil }

    /// Starts `fetch` (once).
    func start(_ fetch: @escaping @MainActor () async -> Value) {
        start { _ in await fetch() }
    }

    /// Starts `fetch` (once), which may hand over what's on screen first
    /// (`show`) before the whole (a folder's first rows — the page opens
    /// with them).
    func start(_ fetch: @escaping @MainActor (_ show: @escaping @MainActor (Value) -> Void) async -> Value) {
        guard !started else { return }
        started = true
        Task { @MainActor in
            let all = await fetch { [weak self] in self?.value = $0 }
            whole = true
            value = all
        }
    }
}

/// Opening a page whose content loads: its data starts at the press, and
/// the page opens once it's in — or after `wait` at the latest, then with
/// placeholders the content takes over as it arrives. One press, one page:
/// a second press while one waits does nothing.
@MainActor
final class PagePreparer {
    static let shared = PagePreparer()
    /// About the transition's own length: cached data is in well before.
    static let wait: Duration = .milliseconds(350)
    private var pages: [String: PreparedPage] = [:]
    /// The page just pressed, for the push's still to wait on.
    private var opening: (page: PreparedPage, deadline: ContinuousClock.Instant)?

    /// `page`, already loading, is kept for the page under `key`; the
    /// page is pushed at once (it builds under the still while the data
    /// comes, `PageFade.push`).
    func open(_ key: String, _ page: PreparedPage, push: @escaping () -> Void) {
        guard !PageFade.shared.busy else { return }
        pages[key] = page
        opening = (page, ContinuousClock.now + Self.wait)
        push()
        opening = nil
    }

    func takeOpening() -> (page: PreparedPage, deadline: ContinuousClock.Instant)? {
        defer { opening = nil }
        return opening
    }

    /// A page's data, loading: started now, kept for the page.
    func open<Value>(_ key: String, fetch: @escaping @MainActor () async -> Value,
                     push: @escaping () -> Void) {
        open(key, showing: { _ in await fetch() }, push: push)
    }

    /// The same, `fetch` handing over the first screen ahead of the whole.
    func open<Value>(_ key: String,
                     showing fetch: @escaping @MainActor (_ show: @escaping @MainActor (Value) -> Void) async -> Value,
                     push: @escaping () -> Void) {
        guard !PageFade.shared.busy else { return }
        let load = PageLoad<Value>()
        load.start(fetch)
        open(key, load, push: push)
    }

    /// What the page's press prepared (nil: opened otherwise — the page
    /// loads by itself).
    func take<Page: PreparedPage>(_ key: String) -> Page? {
        pages.removeValue(forKey: key) as? Page
    }
}

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
        let progress: ProgressStore
        let watched: WatchedStore
    }

    /// Set by Home (its stores); nothing runs before.
    var context: Context?

    /// Focus still for this long: the queue starts.
    static let settle: Double = 0.35
    /// Resting on a title this long: it's warmed fully.
    static let restTime: Double = 0.5
    /// Titles per launch that went to the network.
    static let cap = PerformanceProfile.isLowPower ? 120 : 250
    /// Rows top to bottom: this many titles of each.
    static let perRow = 6

    private var done: [String: Depth] = [:]
    private var settleTask: Task<Void, Never>?
    private var restTask: Task<Void, Never>?
    private var batchedRows = Set<String>()
    private(set) var networkTitles = 0
    private var stats = (jobs: 0, disk: 0, net: 0, ms: 0.0)

    /// Focus moved to `index` in row `row` of `rows` (Home's rows engine).
    func focused(rows: [HomeRow], row: Int, index: Int) {
        guard rows.indices.contains(row), rows[row].items.indices.contains(index) else { return }
        CueRows.Memory.shared.focused(row: rows[row].id, item: rows[row].items[index], index: index)
        guard context != nil else { return }
        settleTask?.cancel()
        restTask?.cancel()
        let item = rows[row].items[index]
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settle))
            guard !Task.isCancelled, let self else { return }
            TitlePictures.shared.focused(item)
            self.plan(rows: rows, row: row, index: index)
        }
        if Self.wanted(item) {
            restTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.restTime))
                guard !Task.isCancelled, let self else { return }
                LoadQueue.shared.add([self.job(item, .full, order: -1)])
            }
        }
    }

    /// Titles only (not episodes, folders, people).
    private static func wanted(_ item: MetaItem) -> Bool { item.type == "movie" || item.type == "series" }

    /// The order, from where focus is: the title and its neighbours (decoded),
    /// a little further along the row and the next row (records), then the
    /// rows top to bottom (records). Replaces what was waiting — in the
    /// queue's focus band, behind what the next press reaches (`LoadQueue`).
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
        let jobs = list.filter { item, depth in
            Self.wanted(item) && done[item.id].map { $0 < depth } ?? true
        }.enumerated().map { index, entry in job(entry.0, entry.1, order: 200 + index) }
        batchRatings(rows)
        LoadQueue.shared.replace(source: "details", with: jobs)
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

    /// One title to `depth`, as a queue job (once per launch per depth;
    /// past `cap` titles from the network, records no more).
    private func job(_ item: MetaItem, _ depth: Depth, order: Int) -> LoadQueue.Job {
        LoadQueue.Job(key: "details:\(item.id):\(depth)", kind: "details", lane: .data, band: .focus,
                      order: order, source: "details") { [weak self] in
            guard let self else { return }
            if let had = self.done[item.id], had >= depth { return }
            let first = self.done[item.id] == nil
            if first, self.networkTitles >= Self.cap, depth < .pictures { return }
            self.done[item.id] = depth
            let t = CACurrentMediaTime()
            let net = await self.warm(item, depth: depth, first: first)
            self.note(item, depth: depth, net: net, ms: (CACurrentMediaTime() - t) * 1000)
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
        // The pictures on disk: the record's and the card's, if different.
        let backdrops = Array(Set([meta.background ?? meta.poster, item.background ?? item.poster].compactMap { $0 }))
        let logo = meta.logo ?? item.logo
        if depth == .record {
            for url in backdrops { _ = await ImageCache.shared.fetchToDisk(url) }
            if let logo { _ = await ImageCache.shared.fetchToDisk(logo) }
            return net
        }
        // Decoded: the one picture Details opens on (TMDB's backdrop, else
        // the card's — `TitlePictures`), at the screen's size. (The add-on's
        // full-screen too was a second large decode Details rarely showed.)
        if let page = await TitlePictures.shared.picture(for: item) ?? item.background ?? item.poster {
            await PicturePreloader.shared.load(.init(page, PictureSize.screen))
        }
        await PicturePreloader.shared.load(.init(logo, PictureSize.logo))
        guard depth == .full else { return net }
        _ = await BlurredBackdrop.image(for: meta.background ?? meta.poster)
        // A show: the season extras (Details asks for every season — the
        // first 10 here) and the stills around Play's episode.
        guard meta.isSeries else { return net }
        if TMDBService.hasAPIKey {
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
            let extras = await TMDBService.seasonEpisodes(imdbID: meta.id, type: meta.type, season: season)
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

/// A tab's page that takes nothing from its parent but closures, made
/// once: they're new on every run of the app's body, so the page (Upcoming's
/// days, Discover's grid) ran its body again on every tab switch. Its own
/// state still updates it.
private struct MadeOnce<Content: View>: View, Equatable {
    @ViewBuilder let content: () -> Content
    static func == (_: Self, _: Self) -> Bool { true }
    var body: some View { content() }
}
