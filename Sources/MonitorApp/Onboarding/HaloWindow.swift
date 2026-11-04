import AppKit
import QuartzCore

@MainActor
final class HaloWindow: NSWindow {
    init(itemFrame: NSRect, pulse: Bool) {
        super.init(contentRect: itemFrame.insetBy(dx: -4, dy: -4), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isOpaque=false; backgroundColor = .clear; ignoresMouseEvents=true; hasShadow=false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view=NSView(frame:NSRect(origin:.zero,size:frame.size)); view.wantsLayer=true
        let shape=CAShapeLayer(); shape.frame=view.bounds
        shape.path=CGPath(roundedRect:view.bounds.insetBy(dx:1,dy:1),cornerWidth:8,cornerHeight:8,transform:nil)
        shape.fillColor=NSColor.clear.cgColor; shape.strokeColor=NSColor.white.withAlphaComponent(0.9).cgColor; shape.lineWidth=1.5
        shape.shadowColor=NSColor.white.cgColor; shape.shadowOpacity=0.35; shape.shadowRadius=6; shape.shadowOffset = .zero
        view.layer?.addSublayer(shape); contentView=view
        orderFrontRegardless()
        if pulse && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse=CAKeyframeAnimation(keyPath:"transform.scale")
            pulse.values=[1,1.06,1]; pulse.keyTimes=[0,0.5,1]; pulse.duration=0.9
            view.layer?.add(pulse,forKey:"tourPulse")
        }
    }
    override var canBecomeKey: Bool { false }
}
