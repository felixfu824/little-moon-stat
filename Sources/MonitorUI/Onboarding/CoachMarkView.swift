import AppKit
import SwiftUI
import MonitorCore

private struct TourHighlightKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    var tourHighlighted: Bool {
        get { self[TourHighlightKey.self] }
        set { self[TourHighlightKey.self] = newValue }
    }
}
/// Applied around the existing card without changing its rendering or subscriptions.
public struct TourPanelHighlight: ViewModifier {
    @Environment(\.tourHighlighted) private var highlighted
    public init() {}
    public func body(content: Content) -> some View {
        content.overlay { if highlighted { RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.9), lineWidth: 2).padding(1).allowsHitTesting(false) } }
    }
}

public struct CoachMarkView: View {
    public let copy: TourCopy, language: AppLanguage, index: Int, count: Int
    public var occluded = false, increaseContrast = false
    @Binding public var mode: DisplayMode
    public var onBack: () -> Void, onNext: () -> Void, onSkip: () -> Void
    @FocusState private var nextFocused: Bool
    private var zh: Bool { language == .traditionalChinese }
    private var last: Bool { index == count - 1 }
    public init(copy: TourCopy, language: AppLanguage, index: Int, count: Int, mode: Binding<DisplayMode>,
                occluded: Bool = false, increaseContrast: Bool = false,
                onBack: @escaping () -> Void = {}, onNext: @escaping () -> Void = {}, onSkip: @escaping () -> Void = {}) {
        self.copy=copy; self.language=language; self.index=index; self.count=count; _mode=mode
        self.occluded=occluded; self.increaseContrast=increaseContrast
        self.onBack=onBack; self.onNext=onNext; self.onSkip=onSkip
    }
    public var body: some View {
        let words = copy.text(language)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MoonModel.phase(step: 3, center: CGPoint(x: 7, y: 7), radius: 6.4)
                    .fill(Color(nsColor: MoonModel.ink(step: 3, dark: true))).frame(width: 14, height: 14).accessibilityHidden(true)
                Text(words.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true).accessibilitySortPriority(10)
            }
            Text(words.body + (occluded ? " " + TourCopy.occluded.text(language).body : ""))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(increaseContrast ? 0.95 : 0.85))
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1).accessibilitySortPriority(9)
            if copy == .mode {
                HStack(spacing: 2) {
                    ForEach(DisplayMode.allCases, id: \.rawValue) { value in
                        Button { mode = value } label: {
                            Text(value.title(language)).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28)
                                .background(.white.opacity(mode == value ? 0.3 : 0), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityAddTraits(mode == value ? .isSelected : [])
                    }
                }.accessibilitySortPriority(8).padding(2).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9)).padding(.top, 12)
            }
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { dot in Circle().fill(.white.opacity(dot == index ? 0.9 : 0.35)).frame(width: 5, height: 5) }
                }.accessibilityHidden(true)
                Spacer(minLength: 0)
                if index > 0 { Button(zh ? "上一步" : "◂ Back", action: onBack).buttonStyle(.plain).fixedSize().foregroundStyle(.white.opacity(0.7)).accessibilitySortPriority(3) }
                Button(zh ? (last ? "完成" : "下一步") : (last ? "Done" : "Next ▸"), action: onNext)
                    .buttonStyle(.plain).fixedSize().font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: 28)
                    .background(.white.opacity(0.22), in: Capsule()).keyboardShortcut(.defaultAction).focused($nextFocused).accessibilitySortPriority(2)
                if !last { Button(zh ? "略過導覽" : "Skip tour", action: onSkip).buttonStyle(.plain).fixedSize().foregroundStyle(.white.opacity(0.7)).accessibilitySortPriority(1) }
            }.font(.system(size: 12)).padding(.top, 14)
        }
        .padding(16).frame(width: 300).foregroundStyle(.white)
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(increaseContrast ? 0.6 : 0.32), lineWidth: 1).allowsHitTesting(false) }
        .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.55), lineWidth: 0.5).frame(height: 1).padding(.horizontal, 18).allowsHitTesting(false) }
        .accessibilityElement(children: .contain).accessibilityLabel(TourCopy.counter(index: index, count: count, language: language))
        .onAppear { nextFocused = true }
        .environment(\.colorScheme, .dark)
    }
}
