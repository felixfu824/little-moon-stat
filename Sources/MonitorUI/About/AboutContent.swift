import Foundation
import MonitorCore

/// Words and facts for the About window. Pure data, so tests can check them without any UI.
public enum AboutContent {
    public struct Credit: Equatable, Sendable {
        public let name: String
        public let url: URL
        /// Shown after the name, e.g. " · MIT". Empty when the README states no license.
        public let license: String
        public let noteEnglish: String
        public let noteChinese: String
        public func note(_ language: AppLanguage) -> String { language == .english ? noteEnglish : noteChinese }
        /// One spoken phrase for VoiceOver.
        public func accessibilityLabel(_ language: AppLanguage) -> String {
            let lic = license.replacingOccurrences(of: " · ", with: "")
            return [name, lic, note(language)].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    public static let appName = "Little Moon"
    public static let author = "Felix Fu"
    public static let coauthors = "Claude (Anthropic), Codex (OpenAI)"
    public static let license = "MIT"
    public static let copyright = "© 2026 Felix Fu"
    public static let repositoryText = "github.com/felixfu824/little-moon-stat"
    public static let repositoryURL = URL(string: "https://github.com/felixfu824/little-moon-stat")!

    /// From the README Credits section.
    public static let credits: [Credit] = [
        Credit(name: "exelban/stats", url: URL(string: "https://github.com/exelban/stats")!, license: " · MIT",
               noteEnglish: "SMC temperature key lists", noteChinese: "SMC 溫度鍵清單"),
        Credit(name: "vladkens/macmon", url: URL(string: "https://github.com/vladkens/macmon")!, license: " · MIT",
               noteEnglish: "Fallback sensor approach", noteChinese: "備援感測器的做法"),
        Credit(name: "dkorunic/iSMC", url: URL(string: "https://github.com/dkorunic/iSMC")!, license: " · GPL-3.0",
               noteEnglish: "Sensor map audit", noteChinese: "感測器對照表稽核"),
        Credit(name: "narugit/smctemp", url: URL(string: "https://github.com/narugit/smctemp")!, license: "",
               noteEnglish: "A further sensor map", noteChinese: "另一份感測器對照表"),
        Credit(name: "jundot/omlx", url: URL(string: "https://github.com/jundot/omlx")!, license: "",
               noteEnglish: "CPU, GPU and memory sampling", noteChinese: "CPU、GPU 與記憶體取樣方式"),
    ]

    public static func subtitle(_ language: AppLanguage) -> String {
        language == .english ? "Mac stats at a glance" : "一眼看懂你的 Mac"
    }
    public static func authorLabel(_ language: AppLanguage) -> String { language == .english ? "Author:" : "作者：" }
    public static func coauthorsLabel(_ language: AppLanguage) -> String { language == .english ? "Co-authors:" : "共同創作者：" }
    public static func licenseLabel(_ language: AppLanguage) -> String { language == .english ? "License:" : "授權：" }
    public static func repositoryLabel(_ language: AppLanguage) -> String { language == .english ? "Repository:" : "程式碼儲存庫：" }
    public static func creditsHeading(_ language: AppLanguage) -> String { language == .english ? "Credits" : "致謝" }

    /// Version line: "Version 0.3.1 (Build 4)" / "版本 0.3.1（組建 4）".
    /// Missing bundle values show "?".
    public static func versionLine(short: String?, build: String?, language: AppLanguage) -> String {
        let v = short?.isEmpty == false ? short! : "?"
        let b = build?.isEmpty == false ? build! : "?"
        return language == .english ? "Version \(v) (Build \(b))" : "版本 \(v)（組建 \(b)）"
    }

    public static func versionLine(bundle: Bundle = .main, language: AppLanguage) -> String {
        versionLine(short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    language: language)
    }
}
