import AppKit
import SwiftUI
import Foundation
import Testing
import MonitorCore
@testable import MonitorUI

@Test func versionLineMatchesLamitypeFormat() {
    #expect(AboutContent.versionLine(short: "0.3.1", build: "4", language: .english) == "Version 0.3.1 (Build 4)")
    #expect(AboutContent.versionLine(short: "0.3.1", build: "4", language: .traditionalChinese) == "版本 0.3.1（組建 4）")
}

@Test func versionLineShowsQuestionMarkForMissingValues() {
    #expect(AboutContent.versionLine(short: nil, build: nil, language: .english) == "Version ? (Build ?)")
    #expect(AboutContent.versionLine(short: "", build: "7", language: .traditionalChinese) == "版本 ?（組建 7）")
}

@Test func versionLineReadsTheBundleKeys() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("about-\(UUID().uuidString).bundle")
    let contents = dir.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let plist: [String: Any] = ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "42", "CFBundleIdentifier": "test.about"]
    try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
    let bundle = try #require(Bundle(url: dir))
    #expect(AboutContent.versionLine(bundle: bundle, language: .english) == "Version 9.8.7 (Build 42)")
}

@Test func creditsMatchTheReadmeAndAreHttpsGitHubLinks() {
    #expect(AboutContent.credits.map(\.name) == ["exelban/stats", "vladkens/macmon", "dkorunic/iSMC", "narugit/smctemp", "jundot/omlx"])
    for credit in AboutContent.credits {
        #expect(credit.url.scheme == "https" && credit.url.host == "github.com")
        #expect(credit.url.path == "/" + credit.name)
        #expect(!credit.noteEnglish.isEmpty && !credit.noteChinese.isEmpty && credit.noteEnglish != credit.noteChinese)
    }
    #expect(AboutContent.credits[2].license == " · GPL-3.0")
    #expect(AboutContent.credits[3].accessibilityLabel(.english) == "narugit/smctemp, A further sensor map")
    #expect(AboutContent.credits[0].accessibilityLabel(.english) == "exelban/stats, MIT, SMC temperature key lists")
}

@Test func repositoryAndFixedFacts() {
    #expect(AboutContent.repositoryURL.absoluteString == "https://github.com/felixfu824/little-moon-stat")
    #expect(AboutContent.repositoryURL.absoluteString.hasSuffix(AboutContent.repositoryText.replacingOccurrences(of: "github.com/", with: "")))
    #expect(AboutContent.appName == "Little Moon" && AboutContent.license == "MIT" && AboutContent.copyright == "© 2026 Felix Fu")
}

@Test(arguments: AppLanguage.allCases) func aboutWordsExistInEveryLanguage(language: AppLanguage) {
    let words = [AboutContent.subtitle(language), AboutContent.authorLabel(language), AboutContent.coauthorsLabel(language),
                 AboutContent.licenseLabel(language), AboutContent.repositoryLabel(language), AboutContent.creditsHeading(language)]
    for word in words { #expect(!word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
}

@Test func aboutWordsDifferBetweenLanguages() {
    #expect(AboutContent.subtitle(.english) == "Mac stats at a glance")
    #expect(AboutContent.subtitle(.traditionalChinese) == "一眼看懂你的 Mac")
    #expect(AboutContent.creditsHeading(.english) != AboutContent.creditsHeading(.traditionalChinese))
}

@Test @MainActor func aboutViewLaysOutAtItsFixedWidthInBothLanguages() {
    var heights: [CGFloat] = []
    for language in AppLanguage.allCases {
        let host = NSHostingView(rootView: AboutView(language: language, versionLine: AboutContent.versionLine(short: "0.3.1", build: "4", language: language), open: { _ in }))
        host.safeAreaRegions = []
        let size = host.fittingSize
        #expect(size.width == AboutView.width)
        #expect(size.height > 300 && size.height < 900)
        heights.append(size.height)
    }
    #expect(heights.count == 2)
}

@Test @MainActor func aboutViewRendersNonBlankInLightAndDark() throws {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let host = NSHostingView(rootView: AboutView(language: .english, versionLine: "Version 0.3.1 (Build 4)", open: { _ in }))
        host.safeAreaRegions = []
        host.appearance = NSAppearance(named: name)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var painted = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 7) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { painted += 1 }
        }
        #expect(painted > 100)
    }
}
