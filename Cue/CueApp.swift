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

/// The remote held while a movement runs to its end (Details opened in
/// place from the billboard, and its Back): presses and directional focus
/// moves are dropped — the screen settling is the sign it takes input
/// again. Focus moves the app makes itself go through.
@MainActor
enum InputHold {
    private(set) static var on = false
    /// Presses dropped at their start: their ends are dropped too.
    private static var dropped: Set<ObjectIdentifier> = []

    static func begin() { on = true }
    static func end() { on = false }
    /// The last press's start (any button).
    private(set) static var lastPress: CFTimeInterval = 0

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
        hookShouldUpdateFocus()
    }

    private typealias Send = @convention(c) (AnyObject, Selector, UIEvent) -> Void
    private static func hookSendEvent() {
        let selector = #selector(UIWindow.sendEvent(_:))
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Send.self)
        let wrapped: @convention(block) (AnyObject, UIEvent) -> Void = { window, event in
            if let presses = (event as? UIPressesEvent)?.allPresses, MainActor.assumeIsolated({ drops(presses) }) { return }
            original(window, selector, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(wrapped))
    }

    private static func drops(_ presses: Set<UIPress>) -> Bool {
        var drop = false
        for press in presses {
            let id = ObjectIdentifier(press)
            if press.phase == .began { lastPress = CACurrentMediaTime() }
            if dropped.contains(id) {
                drop = true
                if press.phase == .ended || press.phase == .cancelled { dropped.remove(id) }
            } else if on, press.phase == .began {
                dropped.insert(id)
                drop = true
            }
        }
        return drop
    }

    private typealias ShouldUpdate = @convention(c) (AnyObject, Selector, UIFocusUpdateContext) -> Bool
    /// The window holds every focused view: asked about every move.
    private static func hookShouldUpdateFocus() {
        let selector = #selector(UIView.shouldUpdateFocus(in:))
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: ShouldUpdate.self)
        let wrapped: @convention(block) (AnyObject, UIFocusUpdateContext) -> Bool = { window, context in
            if MainActor.assumeIsolated({ on }), !context.focusHeading.isEmpty { return false }
            return original(window, selector, context)
        }
        let imp = imp_implementationWithBlock(wrapped)
        if !class_addMethod(UIWindow.self, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
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
                .preferredColorScheme(.dark)
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
        case .folder: return "Folder"
        case .person: return "Cast"
        case .tmdbCompany: return "Studio"
        case .genre: return "Genre"
        case .keyword: return "Tag"
        }
    }

    var probeDetail: String {
        switch self {
        case .detail(let item): return "\(item.name) [\(item.type) \(item.id)]"
        case .folder(let c, let f, _): return "\(c.title) → \(f.title)"
        case .person(_, let name, _): return name
        case .tmdbCompany(_, let name, _, _): return name
        case .genre(_, let name, _, _): return name
        case .keyword(_, let name, _, _): return name
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
    /// Details, a browse page — not a folder (where you started) or a
    /// source list.
    var isTrailPage: Bool {
        switch self {
        case .detail, .person, .tmdbCompany, .genre, .keyword: return true
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
    /// A folder of a collection, opened from its Home row — on Movies /
    /// Series, only that type (`type`).
    case folder(CueCollection, CueCollectionFolder, type: String? = nil)
    /// From Details: `backdrop`, that title's picture (behind the page,
    /// blurred).
    case person(id: Int, name: String, backdrop: String? = nil)
    /// A studio's titles — or a network's (`network`), its shows.
    case tmdbCompany(id: Int, name: String, network: Bool = false, backdrop: String? = nil)
    /// A genre's titles (films or shows).
    case genre(id: Int, name: String, isMovie: Bool, backdrop: String? = nil)
    /// A tag's (TMDB keyword's) titles.
    case keyword(id: Int, name: String, isMovie: Bool, backdrop: String? = nil)

    /// What a pushed page draws behind itself, shown at the press
    /// (`PageFade.push`).
    var pageBackground: AnyView? {
        switch self {
        case .folder: AnyView(ATVBackground())
        case .person(_, _, let backdrop), .tmdbCompany(_, _, _, let backdrop),
             .genre(_, _, _, let backdrop), .keyword(_, _, _, let backdrop):
            AnyView(DetailsBackdropBackground(url: backdrop))
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
    @State private var moviesPath: [Route] = []
    @State private var seriesPath: [Route] = []
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
    @FocusState private var sidebarFocus: Int?
    /// The rail is briefly non-focusable at launch so initial focus lands in
    /// the CONTENT (the app boots with the rail collapsed and a card focused).
    @State private var sidebarEnabled = false
    /// Settings lists lock the top bar out while an entry is moved.
    @ObservedObject private var topBarLock = TopBarLock.shared
    /// Home's page below its billboard: the top bar has gone up with it.
    @ObservedObject private var topBarPlace = TopBarPlace.shared
    /// Into / out of Details in place: the top bar moves out with Home's parts.
    private var billboardOpening = BillboardOpening.shared

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
                    .transition(.asymmetric(insertion: .opacity.animation(PlayStage.fadeIn), removal: .opacity))
                }
            }
            .animation(Motion.fade, value: stage.scene != nil)
            .onOpenURL { handleDeepLink($0) }
            .onChange(of: sidebarFocus) { old, new in traceSidebar(old, new) }
            .onChange(of: sidebarEnabled) { _, new in traceSidebarEnabled(new) }
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
                    // Fix up any already-installed Community Collections after
                    // launch has yielded. Keep network-backed logo migration
                    // out of app-open startup; that runs when the collection
                    // screen is opened.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
                        CommunityCollections.runLaunchMigrations(collections: collections)
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
                    // Settings showing a category (ATVSettingsView reads which):
                    // -accountDemo, or -settingsPage <category>.
                    if args.contains("-accountDemo") || args.contains("-settingsPage") { selectedTab = 3 }
                    if args.contains("-searchDemo") { selectedTab = 1 }
                    if args.contains("-libraryDemo") { selectedTab = 2 }
                    if args.contains("-moviesDemo") { selectedTab = AppTab.movies.rawValue }
                    // A collection's folder, opened from Home (the simulator can't
                    // select): `-folderDemo <n>` — the n-th collection's first.
                    if let flag = args.firstIndex(of: "-folderDemo") {
                        let n = flag + 1 < args.count ? Int(args[flag + 1]) ?? 0 : 0
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            let shelves = collections.collections.filter { !$0.folders.isEmpty }
                            if shelves.indices.contains(n), let folder = shelves[n].folders.first {
                                let route = Route.folder(shelves[n], folder)
                                PageFade.shared.push(key: route, background: route.pageBackground) { homePath.append(route) }
                            }
                        }
                    }
                    // A browse page (genre, tag, studio, network, person),
                    // opened from Home: `-browseDemo <kind> <tmdb id> <name>`.
                    if let flag = args.firstIndex(of: "-browseDemo"), flag + 3 < args.count,
                       let id = Int(args[flag + 2]) {
                        let name = args[flag + 3]
                        let route: Route? = switch args[flag + 1] {
                        case "person": .person(id: id, name: name)
                        case "genre": .genre(id: id, name: name, isMovie: true)
                        case "keyword": .keyword(id: id, name: name, isMovie: true)
                        case "company": .tmdbCompany(id: id, name: name, network: false)
                        case "network": .tmdbCompany(id: id, name: name, network: true)
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
                            sidebarEnabled = true
                            sidebarFocus = 0
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
        // Developer FPS read-out over the whole UI (Settings → Performance).
        .overlay {
            if perf.settings.showFPSOverlay { FPSOverlay() }
        }
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
        case 4: return moviesPath.isEmpty && detailLayers[4]?.leaving != false
        case 5: return seriesPath.isEmpty && detailLayers[5]?.leaving != false
        default: return true   // Settings keeps the rail
        }
    }

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

    private var showSidebar: Bool { !sidebarMovedOut }
    /// Out with the page's parts: off a tab's root, into Details in place,
    /// for the billboard's trailer (with the peek).
    private var sidebarMovedOut: Bool {
        !atTabRoot || billboardOpening.opened || billboardOpening.trailerShown
    }
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
                    // Out for the billboard's trailer: back first (focus
                    // leaving the buttons stops the trailer anyway).
                    if billboardOpening.trailerShown { billboardOpening.trailerShown = false }
                    // Search root with the rail ON SCREEN but inside one of its
                    // short `.disabled` windows (the moments after a tab switch
                    // or a rail exit, kept so the engine seeds focus into the
                    // content). A disabled rail can't take focus, so this Left
                    // failed and was swallowed: the search bar read as a trap
                    // while Back, which force-enables the rail, still worked.
                    // A deliberate Left now takes Back's path. Search only.
                    if selectedTab == 1, showSidebar, !sidebarEnabled, sidebarFocus == nil,
                       playback == nil, launch.gate == nil, !showWelcome {
                        focusSidebar(selectedTab)
                    } else if showSidebar, sidebarFocus == nil, atTabRoot,
                              playback == nil, launch.gate == nil, !showWelcome {
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
                    }
                }

            // Always there: hidden, it moves out the top (and back in) — one
            // motion app-wide (`GlassSidebar.hidden`); on Home, Movies and
            // Series it goes up with the billboard (`TopBarPlace`).
            do {
                let barHidden = !showSidebar
                // (Focus moving along it switches — `switchTab`.)
                GlassSidebar(selected: Binding(get: { selectedTab },
                                               set: { switchTab(to: $0) }),
                             focusBinding: $sidebarFocus,
                             onProfileTap: { launch.showGate(.topBar) },
                             onTabSelected: { newTab in selectTab(newTab) },
                             hidden: sidebarMovedOut,
                             lifted: topBarPlace.pageDown && sidebarFocus == nil
                                && AppTab(rawValue: selectedTab)?.isHomeLike == true)
                    .focusSection()
                    .disabled(barHidden || !sidebarEnabled || !atTabRoot || topBarLock.locked)
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
                                setSidebarEnabled(false, reenableAfter: Self.railSettle)
                            }
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // Stays non-focusable until Home has content to hold
                    // initial focus (onContentReady); timer is the fallback.
                    .task {
                        await LaunchPreloader.shared.lifted()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard !Task.isCancelled else { return }
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
        .animation(perf.motionOn
                   ? billboardOpening.running ? Motion.move : .spring(response: 0.34, dampingFraction: 0.86)
                   : nil, value: showSidebar)
        .animation(perf.motionOn
                   ? .spring(response: 0.34, dampingFraction: 0.86) : nil, value: sidebarFocus != nil)
        // Focus ARRIVING in the rail counts as engaging it, however it got
        // there. `focusSidebar` stamps its own way in, but
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
                    // Search and Library draw no background of their own:
                    // the tab gives them one.
                    .background { if tab == .search || tab == .library { ATVBackground() } }
                    .opacity(active ? 1 : 0)
                    .disabled(!active)
                    .accessibilityHidden(!active)
                    .zIndex(active ? 1 : 0)
            }
        }
        .onChange(of: selectedTab) { _, tab in
            visitedTabs.insert(tab)
            // Home's pages say for themselves (`HomeUIKitView`).
            if AppTab(rawValue: tab)?.isHomeLike != true { TopBarPlace.shared.pageDown = false }
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
        // Navigating pulls the account, as NuvioTV (at most every 2 min).
        sync?.syncOnAppOpen(reason: "tab switch")
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { selectedTab = new }
    }

    /// Every tab built, hidden, once the launch is over — one at a time, so
    /// the first visit is a switch like any other, not a build.
    private func buildTabsAhead() async {
        await LaunchPreloader.shared.lifted()
        for tab in AppTab.topBarOrder where !visitedTabs.contains(tab.rawValue) {
            try? await Task.sleep(for: .seconds(1.5))
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
            NavigationStack {
                ATVSettingsView(barFocused: sidebarFocus != nil) { focusSidebar(3) }
                    .probeScreen("Settings")
                    .environmentObject(searchViewModel)
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
    private func homeLikeStack(_ tab: AppTab, path: Binding<[Route]>, active: Bool) -> some View {
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
            setSidebarEnabled(false, reenableAfter: Self.railSettle)
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
    /// tab's own page, its folders): above it only the page on screen and
    /// the one it came from — opening another, the older ones go. (Deep
    /// in Details — a similar title, a voice actor, a genre… — Back took
    /// as many presses home.)
    private func trail(_ path: Binding<[Route]>) -> Binding<[Route]> {
        Binding(get: { path.wrappedValue }, set: { new in
            let old = path.wrappedValue
            let base = old.prefix { if case .folder = $0 { return true } else { return false } }
            let pages = old.dropFirst(base.count)
            guard let added = new.last, added.isTrailPage, new.count == old.count + 1,
                  Array(new.dropLast()) == old, pages.count >= 2, let kept = pages.last else {
                path.wrappedValue = new
                return
            }
            Self.leave(Array(pages.dropLast()), kept: kept, keepStill: true)
            path.wrappedValue = Array(base) + [kept, added]
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
                    setSidebarEnabled(false, reenableAfter: Self.railSettle)
                }
                .navigationDestination(for: Route.self) { destination(for: $0, path: trail(path)) }
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
        switchTab(to: newTab)
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
        AppProbe.focus("focusSidebar(\(Self.tabName(tab)))  enabled=\(sidebarEnabled.probe)")
        if billboardOpening.trailerShown { billboardOpening.trailerShown = false }
        sidebarEngagedAt = Date()
        setSidebarEnabled(true)
        DispatchQueue.main.async { sidebarFocus = tab }
    }

    /// Back pressed while the rail itself is focused: close the panel. Always
    /// the fast fixed-delay re-enable — nothing is being freshly mounted.
    private func collapseSidebarFromExit() {
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
            // Counted from the launch curtain's lift: under it Home is ready
            // but disabled, and an enabled rail took the first focus.
            await LaunchPreloader.shared.lifted()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            AppProbe.focus("rail re-enabled by timer")
            AppProbe.rail = "enabled"
            sidebarEnabled = true
            sidebarReenableTask = nil
        }
    }

    /// Launched into a screen to look at: no gate covering it.
    static var demoMode: Bool {
        let args = ProcessInfo.processInfo.arguments
        return ["-detailDemo", "-detailDemoSeries", "-homeDemo", "-settingsDemo", "-searchDemo", "-libraryDemo",
                "-discoverDemo", "-accountDemo", "-settingsTabDemo", "-settingsPage"].contains { args.contains($0) }
    }

    /// The gate gone. A profile picked: focus to Home's billboard (its first
    /// button), the top bar settling first (it would take the first focus).
    /// Closed with Back (opened from the top bar): focus back on the avatar.
    private func afterProfileGate(picked: Bool) {
        guard picked else {
            focusSidebar(-1)
            return
        }
        setSidebarEnabled(false, reenableAfter: Self.railSettle)
        if selectedTab == 0 { HomeBack.shared.toBillboard?() }
    }

    // MARK: - Tab roots

    private func homeRoot(_ tab: AppTab, path: Binding<[Route]>, active: Bool) -> some View {
        let filter = tab.typeFilter
        return HomeView(
            viewModel: homeViewModel,
            typeFilter: filter,
            active: active,
            onSelect: { openDetail($0) { openFromHome($0, tab: tab, path: path) } },
            // From the billboard (`DetailTransition` already running).
            onSelectFeatured: { openFromHome(Route.detail($0), tab: tab, path: path) },
            onResume: { resume($0) },
            onStartOver: { resume($0, fromBeginning: true) },
            onChooseSource: { playManuallyFromProgress($0) },
            onOpenFolder: { collection, folder in
                let key = FolderView.loadKey(collection, folder, type: filter)
                PagePreparer.shared.open(key,
                                         showing: { [addonManager, tmdbSettings] show in
                                             await FolderView.catalogs(of: folder, type: filter, key: key,
                                                                       addonManager: addonManager, tmdb: tmdbSettings,
                                                                       show: show)
                                         }) {
                    pushPage(Route.folder(collection, folder, type: filter), path)
                }
            },
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
                TMDBBrowseViewModel.open(.person(id), title: name) {
                    pushPage(Route.person(id: id, name: name), $searchPath)
                }
            },
            onOpenStudio: { id, name in
                TMDBBrowseViewModel.open(.company(id), title: name) {
                    pushPage(Route.tmdbCompany(id: id, name: name), $searchPath)
                }
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

    /// A page (folder, browse page) in: `PageFade`'s crossfade, no slide.
    private func pushPage(_ route: Route, _ path: Binding<[Route]>) {
        PageFade.shared.push(key: route, background: route.pageBackground) { path.wrappedValue.append(route) }
    }

    /// A collection's folder.
    private func folderView(_ collection: CueCollection, _ folder: CueCollectionFolder, type: String?,
                            path: Binding<[Route]>) -> some View {
        FolderView(collection: collection, folder: folder, type: type,
                   onSelect: { openDetail($0) { path.wrappedValue.append($0) } },
                   onOpenInPlace: { item in
                       var transaction = Transaction()
                       transaction.disablesAnimations = true
                       withTransaction(transaction) { path.wrappedValue.append(Route.detail(item)) }
                   })
    }

    /// Details, its pages pushed on `path`.
    private func detailView(_ item: MetaItem, path: Binding<[Route]>, leaving: Bool = false,
                            onBack: @escaping () -> Void) -> some View {
        DetailView(
            item: item,
            onSelectItem: { openDetail($0) { path.wrappedValue.append($0) } },
            onSelectPerson: { id, name, backdrop in
                TMDBBrowseViewModel.open(.person(id), title: name) {
                    pushPage(Route.person(id: id, name: name, backdrop: backdrop), path)
                }
            },
            onSelectCompany: { company, backdrop in
                TMDBBrowseViewModel.open(company.isNetwork ? .network(company.id) : .company(company.id),
                                         title: company.name) {
                    pushPage(Route.tmdbCompany(id: company.id, name: company.name,
                                               network: company.isNetwork, backdrop: backdrop), path)
                }
            },
            onSelectGenre: { genre, isMovie, backdrop in
                TMDBBrowseViewModel.open(.genre(id: genre.id, name: genre.name, isMovie: isMovie),
                                         title: genre.name) {
                    pushPage(Route.genre(id: genre.id, name: genre.name, isMovie: isMovie,
                                         backdrop: backdrop), path)
                }
            },
            onSelectKeyword: { keyword, isMovie, backdrop in
                TMDBBrowseViewModel.open(.keyword(id: keyword.id, isMovie: isMovie), title: keyword.name) {
                    pushPage(Route.keyword(id: keyword.id, name: keyword.name, isMovie: isMovie,
                                           backdrop: backdrop), path)
                }
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
        case .folder(let collection, let folder, let type):
            folderView(collection, folder, type: type, path: path)
        case .person(let id, let name, let backdrop):
            TMDBBrowseView(personID: id, title: name,
                          onSelect: { openDetail($0) { path.wrappedValue.append($0) } },
                          onOpenInPlace: openInPlace(path), backdrop: backdrop)
        case .genre(let id, let name, let isMovie, let backdrop):
            TMDBBrowseView(genreID: id, title: name, isMovie: isMovie,
                          onSelect: { openDetail($0) { path.wrappedValue.append($0) } },
                          onOpenInPlace: openInPlace(path), backdrop: backdrop)
        case .keyword(let id, let name, let isMovie, let backdrop):
            TMDBBrowseView(keywordID: id, title: name, isMovie: isMovie,
                          onSelect: { openDetail($0) { path.wrappedValue.append($0) } },
                          onOpenInPlace: openInPlace(path), backdrop: backdrop)
        case .tmdbCompany(let id, let name, let network, let backdrop):
            TMDBBrowseView(companyID: id, title: name, network: network,
                          onSelect: { openDetail($0) { path.wrappedValue.append($0) } },
                          onOpenInPlace: openInPlace(path), backdrop: backdrop)
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
        // Always a fresh link, the first one, as Play: a remembered URL expires.
        PlayLauncher.shared.play(meta, video, fromStart: fromBeginning)
    }

    /// The source list on the stage.
    private func sources(_ request: SourcePicker.Request) -> some View {
        SourcePanel(meta: request.meta, video: request.video,
                    onPlay: { entry, all in
            sourcePicker.picked = true
            stage.note = nil
            play(request.meta, request.video, entry, all, fromStart: request.fromStart)
        }, onClose: { sourcePicker.close() })
        .id(request.id)
        .ignoresSafeArea()
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
        }
    }

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
        BackgroundStore.shared.cameBack()
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

        // ② The minimum begins with the network: every catalog fresh (Home's
        // own load, started as it was built; each one at most
        // `HomeViewModel.catalogWait`, then its saved copy) and the account's
        // pull (Continue Watching, library — `syncOnAppOpen`), so Home shows
        // the latest and nothing changes under you after the curtain.
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
        line(String(format: "Network   catalogs and sync · %.0f ms", (CACurrentMediaTime() - t) * 1000))

        // The billboard's own picks, made from the fresh rows.
        t = CACurrentMediaTime()
        while !home.picksCurrent, current == generation { try? await Task.sleep(for: .milliseconds(25)) }
        guard current == generation else { return }
        // (Home's own: its first `BillboardPicks.count` — the model holds
        // every tab's.)
        let picks = home.billboard(type: nil).map(\.item)
        let rows = catalogRows(home)
        line(String(format: "Picks     %d · %.0f ms", picks.count, (CACurrentMediaTime() - t) * 1000))

        // One-time artwork (cheap), on the main actor — under the curtain.
        _ = StageArt.shade
        _ = FixedFocusCardEdge.shadowImage
        _ = BillboardShade.image

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

    private func catalogRows(_ home: HomeViewModel) -> [HomeRow] {
        home.entries.compactMap { if case .catalog(let row) = $0 { return row } else { return nil } }
    }

    /// What the first screen draws and one press reaches: the billboard's
    /// first three titles (records, Details' data, picture, logo, colours),
    /// the first row's cards (records, posters), the first card of each of
    /// the 3 rows below in the box (its picture and logo), Continue
    /// Watching's episode stills.
    private func minimumJobs(picks: [MetaItem], rows: [HomeRow], addonManager: AddonManager) -> [LoadQueue.Job] {
        var jobs: [LoadQueue.Job] = []
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
            if let art = item.background ?? item.poster {
                jobs.append(.init(key: "colours:\(art)", kind: "colours", lane: .picture, band: .launch,
                                  order: jobs.count, source: "launch") { _ = await FixedFocusTint.colors(for: art) })
            }
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
        if let progress, let homeSettings, let tmdb {
            let watching = Array(progress.continueWatching(sortMode: homeSettings.continueWatchingSortMode).prefix(6))
            let useEpisodes = tmdb.settings.useEpisodes
            jobs.append(.init(key: "stills", kind: "stills", lane: .data, band: .launch,
                              order: jobs.count, source: "launch") {
                let stills = await ContinueStills.shared.load(watching, useEpisodes: useEpisodes)
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
    /// record (the billboard's, each row's first 15), and their pictures on
    /// disk at the size they show at — not decoded into memory (that would
    /// evict the first screen's). At launch, and coming back once an hour
    /// has passed; only what's a day old asks the network.
    private var deepAt: Date?
    private func deep(force: Bool = false) {
        guard let home else { return }
        if !force, let deepAt, Date().timeIntervalSince(deepAt) < 60 * 60 { return }
        deepAt = Date()
        let picks = home.billboard(type: nil).map(\.item)
        let rows = catalogRows(home)
        let featured = HomeRow(id: Spotlight.featuredRowID, title: "Featured", items: picks)
        TitlePreloader.shared.focused(rows: [featured] + rows, row: 0, index: 0)
        var jobs: [LoadQueue.Job] = []
        for (i, item) in picks.enumerated() {
            jobs.append(.record(item, band: .deep, order: i, source: "deep"))
            if let url = TMDBService.originalSize(item.background) ?? item.poster {
                jobs.append(.disk(url, PictureSize.screen, order: i))
            }
            if let logo = item.logo { jobs.append(.disk(logo, PictureSize.logo, order: i)) }
        }
        for (r, row) in rows.enumerated() {
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
                          order: Int.max, source: "deep") { await BackgroundPicks.shared.score(pool) })
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
        pump()
    }

    /// `source`'s waiting jobs replaced by `jobs` (focus has moved on).
    func replace(source: String, with jobs: [Job]) {
        waiting.removeAll { job in
            guard job.source == source else { return false }
            keys.remove(job.key)
            return true
        }
        add(jobs)
    }

    private func pump() {
        let playing = PlayerController.isPlaying
        waiting.sort { ($0.band.rawValue, $0.order) < ($1.band.rawValue, $1.order) }
        var i = 0
        while i < waiting.count {
            let job = waiting[i]
            let lane = job.lane
            let full = running[lane, default: 0] >= Self.perLane
                || (job.band == .deep && runningDeep[lane, default: 0] >= Self.deepShare(lane))
                || (playing && job.band != .launch)
            if full { i += 1; continue }
            waiting.remove(at: i)
            start(job)
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
        let tmdb: TMDBSettings
        var useEpisodeExtras: Bool { tmdb.useEpisodes }
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
        if let art = item.background ?? item.poster { _ = await FixedFocusTint.colors(for: art) }
        guard depth == .full else { return net }
        _ = await BlurredBackdrop.image(for: meta.background ?? meta.poster)
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
