// Standalone unit test: link MonitorCore plus production MenuText.swift. No UI is shown.
// The real menu order (About directly before Quit, in every settings menu) is asserted by `--menubar-check`.
import MonitorCore

@main struct AboutMenuTests {
    static func main() {
        precondition(MenuText.about.string(.english) == "About Little Moon")
        precondition(MenuText.about.string(.traditionalChinese) == "關於 Little Moon")
        precondition(MenuText.about.string(.english) != MenuText.quit.string(.english))
        print("PASS About menu title en/zh-Hant (3 assertions)")
    }
}
