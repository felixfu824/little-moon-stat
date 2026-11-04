import AppKit
import SwiftUI
import ServiceManagement
import MonitorCore
import Samplers
import MonitorUI

func log(_ message: String) {
    FileHandle.standardError.write(Data("MacMonitorPanel: \(message)\n".utf8))
}

/// Root SwiftUI view. Evaluating `makeCard` inside `body` lets Observation track `store.snapshot`.
private struct CardRoot: View {
    let store: SnapshotStore
    let options: DisplayOptions
    var body: some View { makeCard(store: store, options: options) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let settings = Settings()
    private let store = makeStore()
    private var engine: MonitorEngine!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var moons: MoonStatusController!
    private var popoverOpen = false
    private var statusHidden = false
    private var desktopContentActive = true
    private var sessionLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    private var reportCancellation: SensorReportCancellation?
    private var reportMenuState = SensorReportMenuState()
    private var reportSavePanel: NSSavePanel?
    private var reportMenuItem: NSMenuItem?
    private let about = AboutWindowController()

    private var options = DisplayOptions()
    private var systemAsleep = false
    private var screensAsleep = false
    private var engineRunning = false
    private var launching = true

    private var panelVisible: Bool { panel.isVisible }
    private var detailVisible: Bool { (panelVisible && panel.isUnoccluded) || popoverOpen }
    private var shouldRun: Bool { (detailVisible || options.displayMode != .desktop) && !systemAsleep && !screensAsleep && !sessionLocked }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        options = settings.options
        configureTourArguments()
        if let i = CommandLine.arguments.firstIndex(of: "--display-mode"), i+1 < CommandLine.arguments.count,
           let mode = DisplayMode(rawValue: CommandLine.arguments[i+1]) { options.displayMode = mode }
        engine = makeEngine(store: store)
        configurePresentation(options, engine: engine)
        panel = PanelController(rootView: cardView(), glass: options.glass)
        panel.onOcclusionChanged = { [weak self] in self?.updateRunState() }
        panel.onUserMoved = { [weak self] origin in self?.settings.panelOrigin = origin }

        panel.place(origin: settings.panelOrigin)
        if settings.panelVisible && options.displayMode != .menuBar { panel.show() }
        desktopContentActive = panelVisible
        if !desktopContentActive { panel.setRootView(inactiveCardView()) }
        setSamplingDetails(detailVisible, engine: engine)

        launching = false
        if shouldRun {
            engine.start()
            engineRunning = true
        } else { log("engine pause (hidden launch; no sampling started)") }

        buildStatusItem()
        observeSystem()
        scheduleSimulatedWake()
        scheduleSimulatedMove()
        scheduleSimulatedOptionChange()
        scheduleMenuBarChecks()
        prepareTourLaunch()
        #if DEBUG
        // `--show-about [en|zh]`: opens the About window at launch and logs its CGWindowID (own-window capture only).
        if let i = CommandLine.arguments.firstIndex(of: "--show-about") {
            let zh = i + 1 < CommandLine.arguments.count && CommandLine.arguments[i + 1] == "zh"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                if zh { var o = self.options; o.language = .traditionalChinese; self.setOptions(o) }
                self.showAbout()
                log("TEST about window=\(self.about.window?.windowNumber ?? 0) locked=\(self.sessionLocked) frame=\(NSStringFromRect(self.about.window?.frame ?? .zero))")
            }
        }
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("--sensor-report-ui") {
            DispatchQueue.main.async { [weak self] in self?.sensorReport() }
        }
        #endif
        log("launched visible=\(panelVisible) size=\(options.size.rawValue) glass=\(options.glass.rawValue) "
            + "lang=\(options.language.rawValue) frame=\(NSStringFromRect(panel.frame))")
    }

    func applicationWillTerminate(_ notification: Notification) { tour?.abandon(); reportCancellation?.cancel(); engine.stop() }

    private func cardView() -> AnyView { AnyView(CardRoot(store: store, options: options)) }
    // Keep geometry while removing the hidden card's Observation subscriptions.
    // A bare EmptyView has a 10 pt hosting minimum and would persist a false origin.
    private func inactiveCardView() -> AnyView {
        AnyView(Color.clear.frame(width: panel.frame.width, height: panel.frame.height))
    }

    // MARK: Engine run state (hidden, system sleep, display sleep)

    private func updateRunState() {
        guard !launching else { return }
        tourEnvironmentChanged()
        setDesktopContentActive(panelVisible && panel.isUnoccluded)
        setSamplingDetails(detailVisible, engine: engine)
        if shouldRun, !engineRunning {
            engine.resume()
            engineRunning = true
            log("engine resume")
        } else if !shouldRun, engineRunning {
            engine.pause()
            engineRunning = false
            log("engine pause (visible=\(panelVisible) systemAsleep=\(systemAsleep) screensAsleep=\(screensAsleep) unoccluded=\(panel.isUnoccluded))")
        }
    }

    private func setPanelVisible(_ visible: Bool) {
        if visible && options.displayMode == .menuBar { setMode(.both); return }
        setDesktopContentActive(visible)
        if visible { panel.show() } else { panel.hide() }
        settings.panelVisible = visible
        updateRunState()
    }

    // MARK: System notifications

    private func observeSystem() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.sessionLocked = note.name.rawValue == "com.apple.screenIsLocked"
                    self?.updateRunState()
                }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.systemAsleep = true
                self.updateRunState()
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake(simulated: false) }
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screensAsleep = true
                self.updateRunState()
            }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screensAsleep = false
                self.updateRunState()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.clampToScreen()
                log("screen parameters changed; frame=\(NSStringFromRect(self.panel.frame))")
            }
        }
    }

    /// Shared by the real didWake notification and `--simulate-wake-after`.
    private func handleWake(simulated: Bool) {
        systemAsleep = false
        // A paused engine records the reset and defers all sampling until visible resume.
        engine.systemDidWake()
        log("wake handled via \(simulated ? "simulated" : "NSWorkspace.didWake") path: engine.systemDidWake()")
        updateRunState()
    }

    private func scheduleSimulatedWake() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--simulate-wake-after"), i + 1 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.handleWake(simulated: true) }
        }
    }

    /// `--simulate-move-after <s>`: debug hook that nudges the panel by (+50, -50) like a user drag.
    private func scheduleSimulatedMove() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--simulate-move-after"), i + 1 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.debugNudge(dx: 50, dy: -50)
                log("simulated move; frame=\(NSStringFromRect(self.panel.frame)) saved=\(String(describing: self.settings.panelOrigin))")
            }
        }
    }

    /// `--simulate-options-after <s>`: debug hook that switches to medium + tinted + zh-Hant through the
    /// same path as the menu, to exercise live re-fit without clicking the status item.
    private func scheduleSimulatedOptionChange() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--simulate-options-after"), i + 1 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setOptions(DisplayOptions(size: .medium, glass: .tinted, language: .traditionalChinese))
            }
        }
    }

    // MARK: Options

    private func setOptions(_ new: DisplayOptions) {
        let old = options
        guard new != old else { return }
        options = new
        settings.options = new
        configurePresentation(new, engine: engine)
        if new.glass != old.glass { panel.apply(glass: new.glass) }
        if desktopContentActive { panel.setRootView(cardView()) }
        applyDisplayMode()
        if new.language != old.language { tour?.presentationOptionsChanged(); about.update(language: new.language) }
        log("options size=\(new.size.rawValue) glass=\(new.glass.rawValue) lang=\(new.language.rawValue) "
            + "frame=\(NSStringFromRect(panel.frame))")
    }

    // MARK: Status item and menu

    private func buildStatusItem() {
        moons = MoonStatusController(store: store, options: options)
        statusItem = moons.item
        connectMenuBar(engine: engine) { [weak self] values in self?.moons.refresh(values: values) }
        moons.menu = { [weak self] in
            let menu = NSMenu(); menu.delegate = self; self?.rebuild(menu); return menu
        }
        panel.settingsMenu = moons.menu
        moons.onMode = { [weak self] in self?.setMode($0) }
        moons.onPopover = { [weak self] open in
            guard let self else { return }
            self.popoverOpen = open
            self.tour?.anchorChanged()
            setPopoverSampling(open, engine:self.engine)
            self.updateRunState()
        }
        moons.onVisibility = { [weak self] hidden in
            guard let self else { return }
            self.statusHidden = hidden
            self.tour?.anchorChanged()
            self.applyDisplayMode()
        }
    }

    private func setMode(_ mode: DisplayMode) {
        var o = options; o.displayMode = mode
        if mode != .menuBar { settings.panelVisible = true }
        if o == options { applyDisplayMode() } else { setOptions(o) }
    }
    private func setDesktopContentActive(_ active: Bool) {
        guard desktopContentActive != active else { return }
        desktopContentActive = active
        panel.setRootView(active ? cardView() : inactiveCardView())
    }
    private func applyDisplayMode() {
        let desktop = options.displayMode != .menuBar ? settings.panelVisible : (statusHidden || tourPanelFallback)
        setDesktopContentActive(desktop)
        if desktop { panel.show() } else { panel.hide() }
        moons?.update(options)
        updateRunState()
        log("display mode=\(options.displayMode.rawValue) panel=\(panelVisible) details=\(detailVisible) hidden=\(statusHidden)")
    }
    private func scheduleMenuBarChecks() {
        let args = CommandLine.arguments
        if args.contains("--menubar-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now()+2) { [weak self] in self?.moons.togglePopover() }
        }
        if args.contains("--menubar-check") {
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in
                guard let self else { return }
                let originalFrame = self.panel.frame
                self.setMode(.menuBar)
                log("TEST menubar geometryPreserved=\(self.panel.frame == originalFrame)")
                log("TEST menubar mode panelHidden=\(!self.panelVisible) widthFixed=\(self.statusItem.length == TwinMoonsRenderer.width)")
                self.moons.togglePopover()
                log("TEST menubar popover=\(self.moons.isOpen)")
                self.moons.cancelPopoverForTesting()
                log("TEST menubar escapeCloses=\(!self.moons.isOpen)")
                self.moons.checkVisibility(forceHidden: true)
                log("TEST menubar fallback=\(self.panelVisible)")
                var panelMenus=true
                for mode in DisplayMode.allCases {
                    self.setMode(mode)
                    for control in [false,true] {
                        let context=self.panel.contextMenuForTesting(control:control)
                        let expected=self.moons.menu?()
                        panelMenus = panelMenus && context?.items.map(\.title) == expected?.items.map(\.title)
                            && context?.items.contains(where: { $0.action == #selector(self.quit) }) == true
                            && context?.items.contains(where: { $0.title == (self.options.language == .english ? "Menu bar item hidden by macOS":"macOS 已隱藏選單列項目") }) == true
                    }
                }
                log("TEST menubar panelContextMenus=\(panelMenus)")
                self.checkAbout()
                self.setMode(.both)
                log("TEST menubar both=\(self.panelVisible) widthFixed=\(self.statusItem.length == TwinMoonsRenderer.width)")
                self.setMode(.desktop)
                log("TEST menubar desktop=\(self.panelVisible) minimal=\(self.statusItem.length == NSStatusItem.squareLength)")
                self.setMode(.menuBar)
                var allSubsets=true
                for raw in 0...7 {
                    let target=MenuBarMoons(rawValue:raw)
                    for (i,moon) in MenuBarMoon.allCases.enumerated() where self.options.menuBarMoons.contains(moon.selection) != target.contains(moon.selection) {
                        let row=NSMenuItem(); row.tag=i; self.toggleMoon(row)
                    }
                    let width=raw == 0 ? NSStatusItem.squareLength : TwinMoonsRenderer.width(for:target)
                    allSubsets = allSubsets && self.statusItem.length == width && self.settings.options.menuBarMoons == target
                }
                log("TEST menubar allSubsets=\(allSubsets)")
                NSApp.terminate(nil)
            }
        }
    }

    /// `--menubar-check` part: About sits directly before Quit (after one separator) in every settings menu and
    /// language; the window is a single shared instance, follows the language live, and closes on Esc and Command-W.
    private func checkAbout() {
        let original = options.language
        var order = true
        for language in AppLanguage.allCases {
            var o = options; o.language = language; setOptions(o)
            let menus = [moons.menu?(), panel.contextMenuForTesting(control: false), panel.contextMenuForTesting(control: true)]
            for menu in menus {
                guard let items = menu?.items, items.count >= 3 else { order = false; continue }
                let n = items.count
                order = order && items[n-1].action == #selector(quit) && items[n-1].keyEquivalent == "q"
                    && items[n-2].action == #selector(showAbout) && items[n-2].title == MenuText.about.string(language)
                    && items[n-2].keyEquivalent.isEmpty && items[n-3].isSeparatorItem
            }
        }
        log("TEST menubar aboutBeforeQuit=\(order)")
        var o = options; o.language = .english; setOptions(o)
        showAbout(); showAbout()
        let windows = NSApp.windows.filter { $0 is AboutWindow }
        let window = about.window
        log("TEST about single=\(windows.count == 1) visible=\(about.isVisible) title=\(window?.title ?? "")")
        o.language = .traditionalChinese; setOptions(o)
        log("TEST about liveLanguage=\(window?.title == MenuText.about.string(.traditionalChinese)) width=\(window?.frame.width ?? 0) height=\(window?.frame.height ?? 0)")
        window?.cancelOperation(nil)
        let escCloses = !about.isVisible
        showAbout()
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window?.windowNumber ?? 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                   isARepeat: false, keyCode: 13)
        let handled = key.map { window?.performKeyEquivalent(with: $0) ?? false } ?? false
        log("TEST about escCloses=\(escCloses) commandWCloses=\(handled && !about.isVisible)")
        o.language = original; setOptions(o)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(sensorReport) || reportMenuState.status != .cancelling
    }

    private func t(_ key: MenuText) -> String { key.string(options.language) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(panelVisible ? .hide : .show, #selector(toggleVisible)))
        menu.addItem(.separator())

        let size = NSMenuItem(title: t(.size), action: nil, keyEquivalent: "")
        size.submenu = submenu([
            choice(.large, #selector(pickSize(_:)), tag: 0, on: options.size == .large),
            choice(.medium, #selector(pickSize(_:)), tag: 1, on: options.size == .medium),
        ])
        menu.addItem(size)

        let glass = NSMenuItem(title: t(.glass), action: nil, keyEquivalent: "")
        glass.submenu = submenu([
            choice(.clear, #selector(pickGlass(_:)), tag: 0, on: options.glass == .clear),
            choice(.tinted, #selector(pickGlass(_:)), tag: 1, on: options.glass == .tinted),
        ])
        menu.addItem(glass)

        let lang = NSMenuItem(title: t(.language), action: nil, keyEquivalent: "")
        lang.submenu = submenu([
            choice(.english, #selector(pickLanguage(_:)), tag: 0, on: options.language == .english),
            choice(.traditionalChinese, #selector(pickLanguage(_:)), tag: 1, on: options.language == .traditionalChinese),
        ])
        menu.addItem(lang)
        let zh = options.language == .traditionalChinese
        let temperature = NSMenuItem(title: zh ? "溫度" : "Temperature", action: nil, keyEquivalent: "")
        temperature.submenu = NSMenu()
        for (i, unit) in TemperatureUnit.allCases.enumerated() {
            let title = unit == .system ? (zh ? "系統" : "System") : unit == .celsius ? "°C" : "°F"
            let row = NSMenuItem(title: title, action: #selector(pickTemperature(_:)), keyEquivalent: "")
            row.target = self; row.tag = i; row.state = unit == options.temperatureUnit ? .on : .off
            temperature.submenu?.addItem(row)
        }
        menu.addItem(temperature)
        let moonMenu=NSMenuItem(title:zh ? "選單列月亮" : "Menu bar moons",action:nil,keyEquivalent:"")
        moonMenu.submenu=NSMenu()
        for (i,moon) in MenuBarMoon.allCases.enumerated() {
            let row=NSMenuItem(title:moon.title,action:#selector(toggleMoon(_:)),keyEquivalent:"")
            row.target=self; row.tag=i; row.state=options.menuBarMoons.contains(moon.selection) ? .on:.off
            moonMenu.submenu?.addItem(row)
        }
        menu.addItem(moonMenu)
        let display = NSMenuItem(title: zh ? "顯示" : "Display", action: nil, keyEquivalent: "")
        display.submenu = NSMenu()
        for (i, mode) in DisplayMode.allCases.enumerated() {
            let row = NSMenuItem(title: mode.title(options.language), action: #selector(pickDisplay(_:)), keyEquivalent: "")
            row.target = self; row.tag = i; row.state = mode == options.displayMode ? .on : .off
            display.submenu?.addItem(row)
        }
        menu.addItem(display)
        if moons.parkedByOrganizer {
            let note=NSMenuItem(title:zh ? "選單列項目由整理工具收起" : "Menu bar item parked by organizer",action:nil,keyEquivalent:"")
            note.isEnabled=false; menu.addItem(note)
        }
        if statusHidden {
            let note = NSMenuItem(title: zh ? "macOS 已隱藏選單列項目" : "Menu bar item hidden by macOS", action: nil, keyEquivalent: "")
            note.isEnabled = false; menu.addItem(note)
            let guidance=NSMenuItem(title:zh ? "請檢查系統設定 › 選單列或整理工具" : "Check System Settings › Menu Bar or your organizer",action:nil,keyEquivalent:"")
            guidance.isEnabled=false; menu.addItem(guidance)
        }
        menu.addItem(.separator())

        let login = item(.launchAtLogin, #selector(toggleLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)
        menu.addItem(item(.resetPosition, #selector(resetPosition)))
        menu.addItem(item(.showTour, #selector(showTour)))
        let report = reportMenuState.item(options.language, target: self, action: #selector(sensorReport))
        reportMenuItem = report
        menu.addItem(report)
        menu.addItem(.separator())
        menu.addItem(item(.about, #selector(showAbout)))
        menu.addItem(item(.quit, #selector(quit), key: "q"))
    }

    private func item(_ key: MenuText, _ action: Selector, key equivalent: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t(key), action: action, keyEquivalent: equivalent)
        i.target = self
        return i
    }

    private func choice(_ key: MenuText, _ action: Selector, tag: Int, on: Bool) -> NSMenuItem {
        let i = item(key, action)
        i.tag = tag
        i.state = on ? .on : .off
        return i
    }

    private func submenu(_ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu()
        items.forEach(m.addItem)
        return m
    }

    // MARK: Actions

    @objc private func sensorReport() {
        if let save = reportSavePanel { save.makeKeyAndOrderFront(nil); return }
        if let cancellation = reportCancellation {
            cancellation.cancel()
            reportMenuState.cancel()
            refreshReportMenuItem()
            return
        }
        let cancellation = SensorReportCancellation()
        reportCancellation = cancellation
        reportMenuState.begin()
        if let menu = statusItem.menu { rebuild(menu) }
        DispatchQueue.global(qos: .utility).async { [weak self, appStatus = store.snapshot.status] in
            let result = Result {
                try SensorReportRunner(cancellation: cancellation, appStatus: appStatus) { phase, fraction in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.reportMenuState.update(phase: phase, fraction: fraction)
                        self.refreshReportMenuItem()
                    }
                }.run()
            }
            DispatchQueue.main.async { [weak self] in self?.finishSensorReport(result, cancelled: cancellation.isCancelled) }
        }
    }

    private func refreshReportMenuItem() {
        reportMenuItem?.title = reportMenuState.title(options.language)
        reportMenuItem?.isEnabled = reportMenuState.status != .cancelling
    }

    private func finishSensorReport(_ result: Result<SensorReport, Error>, cancelled: Bool) {
        reportCancellation = nil
        reportMenuState.finish()
        if let menu = statusItem.menu { rebuild(menu) }
        guard !cancelled else { return }
        switch result {
        case .failure(let error):
            #if DEBUG
            if CommandLine.arguments.contains("--sensor-report-ui") {
                log("TEST sensor-report-ui failed: \(error)"); exit(1)
            }
            #endif
            showAlert(title: t(.reportError), detail: error.localizedDescription, offerSettings: false)
        case .success(let report):
            #if DEBUG
            // Acceptance path invokes the exact menu action and worker. Only the
            // destination picker is skipped; release builds ignore this argument.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--sensor-report-ui"), i + 1 < args.count {
                do {
                    try report.write(to: URL(fileURLWithPath: args[i + 1]))
                    log("TEST sensor-report-ui saved: \(report.summary)")
                    NSApp.terminate(nil)
                } catch { log("TEST sensor-report-ui failed: \(error)"); exit(1) }
                return
            }
            #endif
            let save = NSSavePanel()
            save.title = t(.sensorReport)
            save.allowedContentTypes = [.json]
            save.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            save.nameFieldStringValue = "LittleMoon-sensor-report-\(report.machine.model)-\(date).json"
            NSApp.activate()
            reportSavePanel = save
            save.begin { [weak self] response in
                self?.reportSavePanel = nil
                guard response == .OK, let url = save.url else { return }
                do { try report.write(to: url) }
                catch { self?.showAlert(title: self?.t(.reportError) ?? "", detail: error.localizedDescription, offerSettings: false) }
            }
        }
    }

    @objc private func toggleVisible() { setPanelVisible(!panelVisible) }

    @objc private func pickSize(_ sender: NSMenuItem) {
        var o = options
        o.size = sender.tag == 0 ? .large : .medium
        setOptions(o)
    }

    @objc private func pickGlass(_ sender: NSMenuItem) {
        var o = options
        o.glass = sender.tag == 0 ? .clear : .tinted
        setOptions(o)
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        var o = options
        o.language = sender.tag == 0 ? .english : .traditionalChinese
        setOptions(o)
    }

    @objc private func toggleMoon(_ sender: NSMenuItem) {
        var o=options; let selection=MenuBarMoon.allCases[sender.tag].selection
        if o.menuBarMoons.contains(selection) { o.menuBarMoons.remove(selection) } else { o.menuBarMoons.insert(selection) }
        setOptions(o)
    }
    @objc private func pickTemperature(_ sender: NSMenuItem) {
        var o = options; o.temperatureUnit = TemperatureUnit.allCases[sender.tag]; setOptions(o)
    }
    @objc private func pickDisplay(_ sender: NSMenuItem) { setMode(DisplayMode.allCases[sender.tag]) }

    @objc private func resetPosition() { panel.resetPosition() }

    @objc private func showAbout() { about.show(language: options.language) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert(title: t(.loginError), detail: error.localizedDescription, offerSettings: false)
            return
        }
        if service.status == .requiresApproval {
            showAlert(title: t(.launchAtLogin), detail: t(.loginNeedsApproval), offerSettings: true)
        }
    }

    private func showAlert(title: String, detail: String, offerSettings: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: t(.ok))
        if offerSettings { alert.addButton(withTitle: t(.openSettings)) }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { SMAppService.openSystemSettingsLoginItems() }
    }
    // MARK: Tour
    private var tour: TourController?
    private var tourPending = false
    private var tourScheduled = false
    private var tourEarliest = Date.distantPast
    private var tourPanelFallback = false
    private var tourStartIndex = 0
    private var tourDecisionReason = ""
    private var tourCheckSecondRun = false

    private func configureTourArguments() {
        let args = CommandLine.arguments
        if args.contains("--reset-tour") { settings.resetTour() }
        if settings.tourOutcome == TourOutcome.started.rawValue { settings.recordTour(TourOutcome.abandoned.rawValue) }
        if let i=args.firstIndex(of:"--tour-mode"),i+1<args.count,let mode=DisplayMode(rawValue:args[i+1]) { options.displayMode=mode }
        if let i=args.firstIndex(of:"--tour-step"),i+1<args.count,let step=Int(args[i+1]) { tourStartIndex=max(0,step-1) }
    }
    private func prepareTourLaunch() {
        let decision=TourState.launchDecision(version:settings.tourVersion,
            harnessDomain:ProcessInfo.processInfo.environment["MAC_MONITOR_SETTINGS_DOMAIN"] != nil,arguments:CommandLine.arguments)
        tourDecisionReason=decision.reason
        tourPending=decision.run; tourEarliest=Date().addingTimeInterval(3)
        if !decision.run { log("TEST tour autoRun=false reason=\(decision.reason)") }
        tourEnvironmentChanged()
    }
    private func tourEnvironmentChanged() {
        if systemAsleep || screensAsleep || sessionLocked { tour?.abandon(); return }
        guard tourPending, !tourScheduled, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        tourScheduled=true
        DispatchQueue.main.asyncAfter(deadline:.now()+max(0,tourEarliest.timeIntervalSinceNow)) { [weak self] in
            guard let self else { return }; self.tourScheduled=false
            guard !self.systemAsleep, !self.screensAsleep, !self.sessionLocked, self.tourPending else { return }
            self.tourPending=false
            self.startTour(index:self.tourStartIndex)
        }
    }
    @objc private func showTour() {
        tourPending=false
        tourDecisionReason="menu"
        // Re-run is an explicit action, including after a previous completed/skipped tour.
        guard !systemAsleep, !screensAsleep, !sessionLocked else { return }
        startTour(index:0)
    }
    private func startTour(index: Int) {
        tour?.abandon()
        moons.checkVisibility(forceHidden:CommandLine.arguments.contains("--tour-hidden"),forTour:true)
        let controller=TourController(settings:settings,moons:moons,panel:panel,options:{ [weak self] in self?.options ?? DisplayOptions() },
            startIndex:index,showFallback:{ [weak self] in
                guard let self else { return }
                // Keep the Menu bar fallback reachable after hidden/parked tours; it lasts until a mode choice or relaunch.
                if self.options.displayMode == .menuBar { self.tourPanelFallback=true }
                self.setDesktopContentActive(true); self.panel.show(); self.updateRunState()
            },setMode:{ [weak self] in self?.tourPanelFallback=false; self?.setMode($0) },setLanguage:{ [weak self] language in
                guard let self else { return }
                var changed = self.options; changed.language = language; self.setOptions(changed)
            },finished:{ [weak self] in
                self?.tour=nil; self?.updateRunState()
            })
        tour=controller
        if CommandLine.arguments.contains("--tour-check") {
            controller.onFinishedForCheck={ [weak self] outcome in
                guard let self else { return }
                if !self.tourCheckSecondRun && outcome == .completed {
                    self.tourCheckSecondRun=true; self.settings.resetTour()
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [weak self] in self?.startTour(index:0) }
                } else if self.tourCheckSecondRun {
                    log("TEST tour escapeSkipped=\(outcome == .skipped) persisted=\(self.settings.tourOutcome == TourOutcome.skipped.rawValue) date=\(self.settings.tourDate)")
                    NSApp.terminate(nil)
                } else { log("TEST tour checkFailed=true"); NSApp.terminate(nil) }
            }
        }
        controller.start()
        if controller.running { log("TEST tour autoRun=true reason=\(tourDecisionReason.isEmpty ? "menu" : tourDecisionReason)") }
        if CommandLine.arguments.contains("--tour-check") {
            if tourCheckSecondRun {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [weak controller] in controller?.sendEscapeForCheck() }
            } else { controller.runCheck() }
        }
    }

}
