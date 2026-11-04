import AppKit
import SwiftUI
import Observation
import Darwin
import MonitorCore
import MonitorUI

private final class AppearanceProbe: NSView {
    var changed: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); changed?() }
}
@MainActor @Observable private final class PopoverCost { var value: Double? }

/// Store publication and status rendering share one main-actor turn. Appearance,
/// fonts and pixel images are cached independently from the live numeric model.
@MainActor
final class MoonStatusController: NSObject, NSPopoverDelegate {
    let item=NSStatusBar.system.statusItem(withLength:TwinMoonsRenderer.width)
    private let store: SnapshotStore
    private let popover=NSPopover()
    private var options: DisplayOptions
    private var fallbackQuantizer=MenuBarQuantizer()
    private var values: MenuBarValues
    private let cache=NSCache<NSString,NSImage>()
    private var visibleKey=""
    private var appearanceKey=""
    private var dark=false
    private var labelColor=NSColor.labelColor
    private let probe=AppearanceProbe(frame:.zero)
    private var visibilityTimer: Timer?, costTimer: Timer?
    private var baseline: (time:Double,cpu:Double)?
    private let cost=PopoverCost()
    private var hiddenSamples=0
    private(set) var hidden=false
    private(set) var parkedByOrganizer=false
    var onVisibility: ((Bool)->Void)?
    var onPopover: ((Bool)->Void)?
    var onMode: ((DisplayMode)->Void)?
    var menu: (()->NSMenu)?
    var isOpen: Bool { popover.isShown }
    // Tour anchors expose views, never take over ownership of the real popover.
    var anchorView: NSView? { item.button }
    var popoverContentView: NSView? { isOpen ? popover.contentViewController?.view : nil }
    var popoverLevel: Int { popoverContentView?.window?.level.rawValue ?? 0 }
    func setPopoverBehavior(_ behavior: NSPopover.Behavior) { popover.behavior = behavior }
    private var minimal: Bool { options.displayMode == .desktop || options.menuBarMoons.isEmpty }

    init(store: SnapshotStore, options: DisplayOptions) {
        self.store=store; self.options=options
        var quantizer=MenuBarQuantizer(); values=quantizer.update(store.snapshot,unit:options.temperatureUnit); fallbackQuantizer=quantizer
        super.init()
        cache.countLimit=160
        item.autosaveName="MacMonitorPanel.TwinMoons"
        if let button=item.button {
            button.target=self; button.action=#selector(click(_:)); button.sendAction(on:[.leftMouseUp,.rightMouseUp])
            probe.changed={ [weak self] in self?.refreshAppearance() }; button.addSubview(probe)
        }
        popover.behavior = .transient; popover.animates=false; popover.delegate=self
        refreshAppearance()
        configureVisibilityTimer()
        NotificationCenter.default.addObserver(self,selector:#selector(refreshAppearance),name:NSLocale.currentLocaleDidChangeNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(refreshAppearance),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
    }
    func update(_ options: DisplayOptions) { self.options=options; configureVisibilityTimer(); render(); if isOpen { rebuildPopover() } }
    private func configureVisibilityTimer() {
        if options.displayMode == .desktop { visibilityTimer?.invalidate(); visibilityTimer=nil; return }
        guard visibilityTimer == nil else { return }
        visibilityTimer=Timer.scheduledTimer(withTimeInterval:10,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.checkVisibility() } }
        visibilityTimer?.tolerance=2
    }
    func refresh(values: MenuBarValues?) {
        self.values=values ?? fallbackQuantizer.update(store.snapshot,unit:options.temperatureUnit)
        if !minimal { render() }
    }
    @objc private func refreshAppearance() {
        if let button=item.button {
            dark=button.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
            button.effectiveAppearance.performAsCurrentDrawingAppearance { labelColor=NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor }
            appearanceKey="\(button.effectiveAppearance.name.rawValue)|\(labelColor)|\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)"
        }
        render()
        if isOpen { rebuildPopover() }
    }
    private func render() {
        guard let button=item.button else { return }
        if minimal {
            guard visibleKey != "minimal" else { return }
            visibleKey="minimal"; item.length=NSStatusItem.squareLength
            button.image=NSImage(systemSymbolName:"moon",accessibilityDescription:"Little Moon")
            button.setAccessibilityLabel("Little Moon"); reportPresence(); return
        }
        let moons=options.menuBarMoons
        let unit=DisplayFormat.resolvedUnit(options.temperatureUnit)
        let cpu=moons.contains(.cpu) ? DisplayFormat.temperature(values.cpu.number,unit:unit):""
        let gpu=moons.contains(.gpu) ? DisplayFormat.temperature(values.gpu.number,unit:unit):""
        let ram=moons.contains(.ram) ? DisplayFormat.percent(values.ram.number):""
        let key="\(moons.rawValue)|\(values.key(moons))|\(cpu)|\(gpu)|\(ram)|\(appearanceKey)|\(store.snapshot.status.keys.joined(separator: "|"))"
        // Accessibility language can change without changing a single pixel.
        button.setAccessibilityLabel(MoonModel.accessibility(cpu:values.cpu.number,gpu:values.gpu.number,unit:unit,
            language:options.language,ram:values.ram.number,moons:moons,status:store.snapshot.status))
        guard key != visibleKey else { return }
        visibleKey=key
        let width=TwinMoonsRenderer.width(for:moons)
        if item.length != width { item.length=width }
        let cached=cache.object(forKey:key as NSString)
        let image=cached ?? TwinMoonsRenderer.image(cpuText:cpu,gpuText:gpu,cpuStep:values.cpu.phase,gpuStep:values.gpu.phase,
            dark:dark,labelColor:labelColor,ramText:ram,ramStep:values.ram.phase,ramColourStep:values.ram.colour,moons:moons,status:store.snapshot.status)
        if cached == nil { cache.setObject(image,forKey:key as NSString) }
        button.image=image
        reportPresence()
    }
    private func reportPresence() {
        if CommandLine.arguments.contains("--menubar-check") { log("status present=true width=\(item.length) mode=\(options.displayMode.rawValue)") }
    }
    @objc private func click(_ sender: Any?) {
        let event=NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true { showSettings() }
        else { togglePopover() }
    }
    func showSettings() { popover.performClose(nil); guard let menu=menu?(),let button=item.button else { return }; menu.popUp(positioning:nil,at:NSPoint(x:0,y:button.bounds.minY),in:button) }
    func togglePopover() {
        if isOpen { popover.performClose(nil); return }
        guard let button=item.button else { return }
        cost.value=nil; onPopover?(true); rebuildPopover()
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        guard isOpen else { popover.contentViewController=nil; onPopover?(false); log("popover opened=false (presentation unavailable)"); return }
        if let window=popover.contentViewController?.view.window {
            window.makeKey()
            if let host=(popover.contentViewController?.view as? NSGlassEffectView)?.contentView { window.makeFirstResponder(host) }
        }
        baseline=(ProcessInfo.processInfo.systemUptime,Self.cpuTime())
        costTimer=Timer.scheduledTimer(withTimeInterval:10,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.measureCost() } }
        costTimer?.tolerance=2
        log("popover opened=\(isOpen) glass=\(options.glass.rawValue)")
    }
    private func rebuildPopover() {
        let controller=NSViewController(), glass=NSGlassEffectView()
        glass.style=options.glass == .clear && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .clear:.regular
        glass.tintColor=glass.style == .clear ? nil:PanelController.tint; glass.cornerRadius=26
        let host=NSHostingView(rootView:PopoverRoot(store:store,options:options,cost:cost,identity:ObjectIdentifier(self),
            onMode:{ [weak self] in self?.onMode?($0) },onSettings:{ [weak self] in self?.showSettings() },onDismiss:{ [weak self] in self?.popover.performClose(nil) }))
        let size=host.fittingSize; host.sizingOptions=[]; host.frame=NSRect(origin:.zero,size:size); host.autoresizingMask=[.width,.height]
        glass.contentView=host; glass.frame=NSRect(origin:.zero,size:size); controller.view=glass
        popover.contentViewController=controller; popover.contentSize=size
        if isOpen { popover.contentViewController?.view.window?.makeFirstResponder(host) }
    }
    func cancelPopoverForTesting() {
        guard let window=popover.contentViewController?.view.window,
              let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) else { return }
        window.sendEvent(event)
    }
    func popoverDidClose(_ notification: Notification) { costTimer?.invalidate(); costTimer=nil; popover.contentViewController=nil; onPopover?(false); log("popover opened=false") }
    private static func cpuTime() -> Double {
        func usage(_ who:Int32)->Double { var u=rusage(); guard getrusage(who,&u)==0 else { return 0 }; return Double(u.ru_utime.tv_sec+u.ru_stime.tv_sec)+Double(u.ru_utime.tv_usec+u.ru_stime.tv_usec)/1e6 }
        return usage(RUSAGE_SELF)+usage(RUSAGE_CHILDREN)
    }
    private func measureCost() {
        let now=ProcessInfo.processInfo.systemUptime,cpu=Self.cpuTime()
        if let baseline,now>baseline.time { cost.value=max(0,(cpu-baseline.cpu)/(now-baseline.time)*100) }
        baseline=(now,cpu)
    }
    func checkVisibility(forceHidden:Bool=false, forTour:Bool=false) {
        guard forTour || forceHidden || !minimal || options.displayMode == .menuBar else { return }
        let button=item.button
        let frame=button.flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds,to:nil)) } } ?? .zero
        let screenVisible=NSScreen.screens.contains { s in
            guard s.frame.contains(frame) else { return false }
            if let left=s.auxiliaryTopLeftArea,let right=s.auxiliaryTopRightArea,frame.maxY>s.frame.maxY-s.safeAreaInsets.top { return left.contains(frame)||right.contains(frame) }
            return true
        }
        let shown=item.isVisible && button?.window?.isVisible == true && frame.width>1 && frame.height>1 && screenVisible
        let minX=NSScreen.screens.map { $0.frame.minX }.min() ?? 0
        let widest=NSScreen.screens.map { $0.frame.width }.max() ?? 1440
        // Corroborate deliberate far-offscreen parking with the known organiser.
        // Never infer organiser intent from a notch/zero frame or isVisible=false.
        let parked = !forceHidden && item.isVisible && frame.width>1 && frame.maxX < minX-widest
            && !NSRunningApplication.runningApplications(withBundleIdentifier:"com.stonerl.Thaw").isEmpty
        hiddenSamples=forceHidden || (!shown && !parked) ? hiddenSamples+1:0
        let next=forceHidden || hiddenSamples>=2
        if next != hidden || parked != parkedByOrganizer {
            hidden=next; parkedByOrganizer=parked; onVisibility?(next)
            log("status hidden=\(next) parked=\(parked) frame=\(frame)")
        }
    }
    deinit { visibilityTimer?.invalidate(); costTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }
}
private struct PopoverRoot: View {
    let store:SnapshotStore, options:DisplayOptions, cost:PopoverCost
    let identity:ObjectIdentifier
    let onMode:(DisplayMode)->Void, onSettings:()->Void, onDismiss:()->Void
    var body:some View { MoonPopover(snapshot:store.snapshot,options:options,cost:cost.value,onMode:onMode,onSettings:onSettings,actionIdentity:identity).onExitCommand(perform:onDismiss) }
}
