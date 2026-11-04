import SwiftUI
import AppKit
import MonitorCore

/// Content of the About window ("Moon card"): the three moons lead, then the facts and credits.
/// Colors are system colors only, so light/dark and Increase Contrast follow the system.
public struct AboutView: View {
    public static let width: CGFloat = 440
    /// Space the transparent title bar occupies (the window uses a full-size content view).
    public static let titleBarInset: CGFloat = 34

    private let language: AppLanguage
    private let versionLine: String
    private let open: (URL) -> Void

    public init(language: AppLanguage, versionLine: String, open: @escaping (URL) -> Void) {
        self.language = language
        self.versionLine = versionLine
        self.open = open
    }

    public var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                AboutMoons()
                    .accessibilityHidden(true)
                VStack(spacing: 3) {
                    Text(AboutContent.appName).font(.system(size: 24, weight: .bold))
                    Text(AboutContent.subtitle(language)).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Text(versionLine)
                    .font(.system(size: 12).monospacedDigit())
                    .padding(.horizontal, 11).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
                row(AboutContent.authorLabel(language)) { Text(AboutContent.author) }
                row(AboutContent.coauthorsLabel(language)) { Text(AboutContent.coauthors) }
                row(AboutContent.licenseLabel(language)) { Text(AboutContent.license) }
                row(AboutContent.repositoryLabel(language)) {
                    linkButton(AboutContent.repositoryText, url: AboutContent.repositoryURL)
                }
            }
            .modifier(Inset())

            VStack(alignment: .leading, spacing: 6) {
                Text(AboutContent.creditsHeading(language))
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(language == .english ? .uppercase : nil)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(AboutContent.credits, id: \.name) { credit in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 0) {
                                linkButton(credit.name, url: credit.url)
                                Text(credit.license).foregroundStyle(.secondary)
                            }
                            Text(credit.note(language)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(credit.accessibilityLabel(language))
                        .accessibilityAddTraits(.isLink)
                        .accessibilityAction { open(credit.url) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(Inset())
            }

            Text(AboutContent.copyright).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 22)
        .padding(.top, Self.titleBarInset)
        .padding(.bottom, 20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func linkButton(_ title: String, url: URL) -> some View {
        Button { open(url) } label: { Text(title).foregroundStyle(Color(nsColor: .linkColor)) }
            .buttonStyle(.plain)
            .pointerStyle(.link)
    }

    private struct Inset: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

/// Decorative CPU / GPU / RAM moons at fixed, calm phases. No readings are shown.
struct AboutMoons: View {
    @Environment(\.colorScheme) private var scheme

    private enum Kind { case cpu, gpu, ram }
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            moon(.cpu, step: 4, label: "CPU")
            moon(.gpu, step: 2, label: "GPU")
            moon(.ram, step: 4, label: "RAM")
        }
    }

    private func moon(_ kind: Kind, step: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let s = size.width / 16
                let c = CGPoint(x: 8 * s, y: 8 * s)
                let r = (kind == .cpu ? 6.4 : 5.3) * s
                let ink = Color(nsColor: MoonModel.ink(step: step, dark: scheme == .dark))
                let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(disc, with: .color(ink.opacity(0.16)))
                ctx.stroke(disc, with: .color(ink.opacity(0.55)), lineWidth: 0.35 * s)
                ctx.fill(MoonModel.phase(step: step, center: c, radius: r), with: .color(ink))
                if kind != .cpu {
                    let ro = 7.3 * s
                    let ring = Path(ellipseIn: CGRect(x: c.x - ro, y: c.y - ro, width: 2 * ro, height: 2 * ro))
                    let dash: [CGFloat] = kind == .ram ? [1.2 * s, 1.35 * s] : []
                    ctx.stroke(ring, with: .color(ink.opacity(kind == .ram ? 0.95 : 0.9)),
                               style: StrokeStyle(lineWidth: (kind == .ram ? 0.45 : 0.4) * s, dash: dash))
                }
            }
            .frame(width: 58, height: 58)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}
