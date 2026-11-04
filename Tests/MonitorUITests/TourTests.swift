import XCTest
import AppKit
import MonitorCore
@testable import MonitorUI

final class TourTests: XCTestCase {
    func testAllPlans() {
        for mode in DisplayMode.allCases {
            for hidden in [false,true] {
                for panel in [false,true] {
                    let state=TourState(mode:mode,hidden:hidden,panelVisible:panel)
                    XCTAssertEqual(state.steps.contains(.popover),!hidden)
                    XCTAssertEqual(state.steps.contains(.panel),mode != .menuBar && panel)
                    XCTAssertEqual(state.steps.first,.moons); XCTAssertEqual(state.steps.last,.mode)
                }
            }
        }
    }
    func testNavigationAndOutcomes() {
        var state=TourState(mode:.both,hidden:false,panelVisible:true)
        XCTAssertNil(state.outcome); state.start(); XCTAssertEqual(state.outcome,.started)
        state.back(); XCTAssertEqual(state.index,0)
        state.next(); XCTAssertEqual(state.step,.popover)
        state.back(); XCTAssertEqual(state.step,.moons)
        while !state.isLast { state.next() }; state.next(); XCTAssertEqual(state.outcome,.completed)
        state.back(); XCTAssertTrue(state.isLast)
    }
    func testSkipAbandonAndFinalEscape() {
        var state=TourState(mode:.menuBar,hidden:true,panelVisible:true)
        state.start(); state.skip(); XCTAssertEqual(state.outcome,.skipped)
        state.abandon(); XCTAssertEqual(state.outcome,.skipped)
        state=TourState(mode:.desktop,hidden:false,panelVisible:true); state.start(); state.abandon(); XCTAssertEqual(state.outcome,.abandoned)
        state=TourState(mode:.both,hidden:false,panelVisible:true,startIndex:999); state.start(); state.skip(); XCTAssertEqual(state.outcome,.completed)
    }
    func testLaunchPolicyIncludingExistingInstallAndFutureVersion() {
        // Existing size/glass/etc keys are deliberately absent from the policy: only tourVersion gates it.
        XCTAssertTrue(TourState.launchDecision(version:0,harnessDomain:false,arguments:[]).run)
        for version in [1,2,100] { XCTAssertFalse(TourState.launchDecision(version:version,harnessDomain:false,arguments:[]).run) }
        XCTAssertFalse(TourFlow.showWhatsNew)
        XCTAssertEqual(TourState.launchDecision(version:0,harnessDomain:true,arguments:[]).reason,"harness-domain")
        XCTAssertEqual(TourState.launchDecision(version:0,harnessDomain:false,arguments:["--preview-engine"]).reason,"debug-argument")
        for arg in ["--tour","--tour-check","--tour-step"] { XCTAssertTrue(TourState.launchDecision(version:1,harnessDomain:true,arguments:[arg]).run) }
        XCTAssertTrue(TourState.launchDecision(version:0,harnessDomain:false,arguments:["--reset-tour"]).run)
        XCTAssertFalse(TourState.launchDecision(version:1,harnessDomain:false,arguments:["--tour-mode","both"]).run)
    }
    func testInterruptedAndLegacyRestoration() {
        XCTAssertEqual(TourState.restoredOutcome("started"),.abandoned)
        XCTAssertEqual(TourState.restoredOutcome("legacy"),.legacy)
        XCTAssertEqual(TourState.restoredOutcome("completed"),.completed)
        XCTAssertNil(TourState.restoredOutcome(nil))
        XCTAssertNil(TourState.restoredOutcome("unknown"))
    }
    func testCopyAndMinimalIconPolicy() {
        for key in TourCopy.allCases {
            for language in AppLanguage.allCases {
                let text=key.text(language)
                XCTAssertFalse(text.body.isEmpty)
                XCTAssertLessThanOrEqual(text.body.count,language == .english ? 150 : 70,"\(key)")
                if key != .occluded { XCTAssertFalse(text.title.isEmpty) }
                if language == .english { XCTAssertLessThanOrEqual(text.title.count,28) }
                XCTAssertFalse((text.title+text.body).contains("—")); XCTAssertFalse((text.title+text.body).contains("–"))
            }
        }
        XCTAssertEqual(TourCopy.key(step:.moons,mode:.desktop,hidden:false,parked:false,moonsEmpty:true),.minimal)
        for mode in [DisplayMode.menuBar,.both] {
            XCTAssertEqual(TourCopy.key(step:.moons,mode:mode,hidden:false,parked:false,moonsEmpty:true),.icon)
        }
        XCTAssertEqual(TourCopy.key(step:.moons,mode:.menuBar,hidden:true,parked:true,moonsEmpty:true),.parked)
        for language in AppLanguage.allCases {
            XCTAssertFalse(TourCopy.popover.text(language).body.contains("Esc"))
            XCTAssertLessThanOrEqual((TourCopy.panel.text(language).body+" "+TourCopy.occluded.text(language).body).count,language == .english ? 150 : 70)
        }
    }
    func testPlacement() {
        let screen=CGRect(x:0,y:0,width:1440,height:900)
        for item in [CGRect(x:1100,y:878,width:200,height:22),CGRect(x:1250,y:866,width:100,height:34)] {
            XCTAssertEqual(CoachMarkPlacement.preferredEdge(anchor:item,screen:screen,kind:.item),.minY)
        }
        XCTAssertEqual(CoachMarkPlacement.preferredEdge(anchor:CGRect(x:1000,y:400,width:360,height:400),screen:screen,kind:.panel),.minX)
        XCTAssertEqual(CoachMarkPlacement.preferredEdge(anchor:CGRect(x:10,y:400,width:360,height:400),screen:screen,kind:.panel),.maxX)
        XCTAssertEqual(CoachMarkPlacement.preferredEdge(anchor:CGRect(x:100,y:400,width:360,height:400),screen:screen,kind:.popover),.minY)
        XCTAssertEqual(CoachMarkPlacement.preferredEdge(anchor:CGRect(x:1000,y:400,width:360,height:400),screen:screen,kind:.popover),.minX)
        XCTAssertEqual(CoachMarkPlacement.preferredEdge(anchor:CGRect(x:0,y:0,width:500,height:500),screen:CGRect(x:0,y:0,width:600,height:600),kind:.panel),.maxY)
    }
}
