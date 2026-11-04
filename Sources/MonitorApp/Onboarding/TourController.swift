import AppKit
import SwiftUI
import MonitorCore
import MonitorUI

/// All tour-only resources are owned here and torn down on every terminal outcome.
@MainActor
final class TourController {
    private let settings: Settings
    private let anchors: TourAnchors
    private let options: () -> DisplayOptions
    private let setMode: (DisplayMode) -> Void
    private let setLanguage: (AppLanguage) -> Void
    private let showFallback: () -> Void
    private let finished: () -> Void
    private var state: TourState
    private var coach: NSPopover?
    private var halo: HaloWindow?
    private var keyboard: Any?
    private var idle: Timer?
    private var observers: [NSObjectProtocol] = []
    private var popoverWasOpen = false
    private var transitioning = false
    private var didPersistStart = false
    private var initialPanelVisible: Bool
    private var initiallyHidden: Bool
    private var currentAnchor: TourAnchorKind?
    private var raisedPanel = false
    private(set) var running = false
    var onFinishedForCheck: ((TourOutcome) -> Void)?

    init(settings: Settings, moons: MoonStatusController, panel: PanelController, options: @escaping () -> DisplayOptions,
         startIndex: Int, showFallback: @escaping () -> Void, setMode: @escaping (DisplayMode) -> Void, setLanguage: @escaping (AppLanguage) -> Void, finished: @escaping () -> Void) {
        self.settings=settings; anchors=TourAnchors(moons:moons,panel:panel); self.options=options
        self.setMode=setMode; self.setLanguage=setLanguage; self.showFallback=showFallback; self.finished=finished
        initialPanelVisible=panel.isVisible
        initiallyHidden = !anchors.itemAvailable
        if initiallyHidden { showFallback() }
        state=TourState(mode:options().displayMode,hidden:initiallyHidden,panelVisible:panel.isVisible,startIndex:startIndex)
    }
    func start() {
        running=true; state.start()
        keyboard=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown]) { [weak self] event in
            guard let self, self.running else { return event }
            self.touch()
            if event.type == .keyDown {
                switch event.keyCode {
                case 53: self.skip(); return nil
                case 123: self.back(); return nil
                case 124,36,76: self.next(); return nil
                default: break
                }
            }
            return event
        }
        let workspace=NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.abandon() } })
        }
        observers.append(workspace.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.anchorChanged() } })
        observers.append(DistributedNotificationCenter.default().addObserver(forName:Notification.Name("com.apple.screenIsLocked"),object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.abandon() } })
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.anchorChanged() } })
        if let itemWindow=anchors.moons.anchorView?.window {
            for name in [NSWindow.didMoveNotification,NSWindow.didChangeOcclusionStateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:itemWindow,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.anchorChanged() }
                })
            }
        }
        touch(); present(entering: true)
    }
    func next() { navigate { $0.next() } }
    func back() { guard state.index > 0 else { touch(); return }; navigate { $0.back() } }
    func skip() { navigate { $0.skip() } }
    func abandon() { guard running else { return }; state.abandon(); finish() }
    private func navigate(_ change: (inout TourState) -> Void) {
        guard running, !transitioning else { return }
        touch(); leaveStep(); change(&state)
        if state.outcome != .started { finish() } else { present(entering: true) }
    }
    private func touch() {
        idle?.invalidate()
        idle=Timer.scheduledTimer(withTimeInterval:600,repeats:false) { [weak self] _ in MainActor.assumeIsolated { self?.abandon() } }
    }
    func anchorChanged() {
        guard running, !transitioning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, !self.transitioning else { return }
            if !self.anchors.itemAvailable && !self.anchors.desktop.usable { self.showFallback() }
            self.present(entering: false)
        }
    }
    /// Rebuild copy and accessibility labels without step entry/exit side effects.
    func presentationOptionsChanged() {
        guard running, !transitioning else { return }
        present(entering: false)
    }
    private func present(entering: Bool) {
        guard running else { return }
        transitioning=true
        if entering {
            if state.step == .popover {
                popoverWasOpen=anchors.moons.isOpen
                anchors.moons.setPopoverBehavior(.applicationDefined)
                if !popoverWasOpen { anchors.moons.togglePopover() }
            }
        }
        guard let anchor=anchors.resolve(state.step) else { transitioning=false; abandon(); return }
        if anchor.kind == .panel {
            if !raisedPanel { anchors.panel.setLevel(.floating); anchors.panel.setTourHighlight(true); raisedPanel = true }
        } else if raisedPanel { restorePanel() }
        currentAnchor=anchor.kind
        coach?.close(); halo?.orderOut(nil); halo=nil
        let o=options(), hidden = !anchors.itemAvailable
        let copy=TourCopy.key(step:state.step,mode:o.displayMode,hidden:hidden,parked:anchors.moons.parkedByOrganizer,moonsEmpty:o.menuBarMoons.isEmpty)
        let view=CoachMarkView(copy:copy,language:o.language,index:state.index,count:state.steps.count,
            mode:Binding(get:{ [weak self] in self?.options().displayMode ?? .both },set:{ [weak self] value in
                self?.selectMode(value)
            }),occluded:state.step == .panel && !anchors.panel.isUnoccluded,
            increaseContrast:NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            onBack:{ [weak self] in self?.back() },onNext:{ [weak self] in self?.next() },onSkip:{ [weak self] in self?.skip() })
        let host=NSHostingView(rootView:view),glass=NSGlassEffectView(),vc=NSViewController()
        host.setAccessibilityLabel(TourCopy.counter(index:state.index,count:state.steps.count,language:o.language))
        let size=host.fittingSize
        host.frame=NSRect(origin:.zero,size:size); host.autoresizingMask=[.width,.height]
        glass.style = .regular; glass.tintColor=PanelController.tint; glass.cornerRadius=18
        glass.contentView=host; glass.frame=host.frame; vc.view=glass
        let pop=NSPopover(); pop.behavior = .applicationDefined
        pop.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pop.contentViewController=vc; pop.contentSize=size; coach=pop
        pop.show(relativeTo:anchor.view.bounds,of:anchor.view,preferredEdge:CoachMarkPlacement.preferredEdge(anchor:anchor.frame,screen:anchor.screen,kind:anchor.kind))
        if let window=vc.view.window {
            // Explicitly preserve ordering even for a coach attached to a desktop-level window.
            window.level = .init(rawValue:max(NSWindow.Level.statusBar.rawValue+2,anchors.moons.popoverLevel))
            window.makeKey(); window.makeFirstResponder(host)
            NSAccessibility.post(element:host,notification:.announcementRequested,userInfo:[
                .announcement:TourCopy.counter(index:state.index,count:state.steps.count,language:o.language)+", "+copy.text(o.language).title,
                .priority:NSAccessibilityPriorityLevel.high.rawValue])
        }
        if anchor.kind == .item && state.step != .popover { halo=HaloWindow(itemFrame:anchor.frame,pulse:entering) }
        transitioning=false
        guard pop.isShown else { abandon(); return }
        if !didPersistStart {
            didPersistStart=true; settings.recordTour(TourOutcome.started.rawValue)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [weak self,weak pop] in
            guard let self, self.running, self.coach === pop else { return }
            self.logPresentation()
        }
    }
    private func selectMode(_ mode: DisplayMode) {
        touch(); setMode(mode); anchorChanged()
    }
    private func leaveStep() {
        transitioning=true
        coach?.close(); coach=nil; halo?.orderOut(nil); halo=nil
        if state.step == .popover {
            anchors.moons.setPopoverBehavior(.transient)
            if !popoverWasOpen && anchors.moons.isOpen { anchors.moons.togglePopover() }
        }
        restorePanel()
        transitioning=false
    }
    private func restorePanel() {
        guard raisedPanel else { return }
        anchors.panel.setLevel(.init(rawValue:NSWindow.Level.normal.rawValue-1))
        anchors.panel.setTourHighlight(false); raisedPanel = false
    }
    private func finish() {
        guard running else { return }
        running=false; leaveStep()
        idle?.invalidate(); idle=nil
        if let keyboard { NSEvent.removeMonitor(keyboard) }; keyboard=nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        let outcome=state.outcome ?? .abandoned
        if didPersistStart { settings.recordTour(outcome.rawValue) }
        if initiallyHidden && !initialPanelVisible && !settings.panelVisible && options().displayMode != .menuBar { anchors.panel.hide() }
        log("TEST tour teardown=\(coach == nil && halo == nil && idle == nil && keyboard == nil && observers.isEmpty) panelLevel=\(anchors.panel.hostView.window?.level.rawValue ?? 0)")
        log("TEST tour outcome=\(outcome.rawValue) version=\(settings.tourVersion)")
        let completion=onFinishedForCheck
        finished(); completion?(outcome)
    }
    private func logPresentation() {
        guard let window=coach?.contentViewController?.view.window else { return }
        // Metadata only, restricted to this process. Never captures pixels.
        let windows=CGWindowListCopyWindowInfo([.optionAll],kCGNullWindowID) as? [[String:Any]] ?? []
        let own=windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        let onScreen=own?[kCGWindowIsOnscreen as String] as? Bool == true && NSScreen.screens.contains { $0.frame.contains(window.frame) }
        let level=own?[kCGWindowLayer as String] as? Int ?? window.level.rawValue
        log("TEST tour step=\(state.step.rawValue) index=\(state.index+1)/\(state.steps.count) anchor=\(currentAnchor?.rawValue ?? "none") frame=\(NSStringFromRect(window.frame)) onScreen=\(onScreen) level=\(level) key=\(window.isKeyWindow) panelLevel=\(anchors.panel.hostView.window?.level.rawValue ?? 0) moonLevel=\(anchors.moons.popoverLevel) window=\(window.windowNumber) halo=\(halo?.windowNumber ?? 0)")
    }
    /// Exercises the controller's real navigation and NSEvent keyboard route, then a second Skip run.
    func runCheck() {
        var actions: [@MainActor @Sendable () -> Void] = [{ [weak self] in self?.next() },{ [weak self] in self?.back() }]
        actions += (0..<max(0,state.steps.count-state.index-1)).map { _ in { [weak self] in
            self?.next(); self?.checkLanguages()
        } }
        actions.append { [weak self] in
            guard let self else { return }
            let original=self.options().displayMode, plan=self.state.steps
            var valid=true
            for mode in DisplayMode.allCases {
                self.selectMode(mode)
                valid = valid && self.options().displayMode == mode && self.settings.options.displayMode == mode
            }
            self.selectMode(original)
            log("TEST tour modePicker=\(valid) planFixed=\(self.state.steps == plan)")
        }
        actions.append { [weak self] in self?.next() }
        for (i,action) in actions.enumerated() {
            DispatchQueue.main.asyncAfter(deadline:.now()+Double(i+1)*0.8,execute:action)
        }
    }
    private func checkLanguages() {
        guard state.step == .settings || state.step == .mode else { return }
        let index = state.index, plan = state.steps, original = options().language
        let popoverOpen = anchors.moons.isOpen, raised = raisedPanel
        var valid = true
        for language in [original == .english ? AppLanguage.traditionalChinese : .english, original] {
            let previous = coach
            setLanguage(language)
            let host = (coach?.contentViewController?.view as? NSGlassEffectView)?.contentView as? NSHostingView<CoachMarkView>
            valid = valid && coach !== previous && host?.rootView.language == language
                && host?.rootView.copy.text(language).title == TourCopy.key(step:state.step,mode:options().displayMode,
                    hidden:!anchors.itemAvailable,parked:anchors.moons.parkedByOrganizer,moonsEmpty:options().menuBarMoons.isEmpty).text(language).title
                && host?.accessibilityLabel() == TourCopy.counter(index:index,count:plan.count,language:language)
                && state.index == index && state.steps == plan && anchors.moons.isOpen == popoverOpen && raisedPanel == raised
        }
        if options().language != original { setLanguage(original) }
        log("TEST tour languageRefresh=\(valid) step=\(state.step.rawValue) directions=zh-Hant,en accessibility=true")
    }
    func sendEscapeForCheck() {
        guard let window=coach?.contentViewController?.view.window,
              let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) else { return }
        NSApp.postEvent(event,atStart:true)
    }
}
