//
//  MenuBarEnergyTests.swift
//
//  Regression tests for v0.9.1: the menu-bar item must not leak memory per
//  update on macOS 27, and the closed popover must not keep refreshing.
//

import XCTest
import AppKit
import SwiftUI
@testable import Airway

private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return Double(info.phys_footprint) / 1_048_576
}

@MainActor
final class MenuBarEnergyTests: XCTestCase {

    private var statusItem: NSStatusItem!
    private var renderer: StatusItemRenderer!

    override func setUp() async throws {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderer = StatusItemRenderer(statusItem: statusItem, symbolName: "wind")
    }

    override func tearDown() async throws {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func testMenuBarUpdatesDoNotLeak() {
        // The old image-per-update code grew ~115 KB per update (~336 MB here).
        // A control pass with unchanged content (which the renderer skips)
        // measures whatever else the test host is doing in the same time, so
        // only the menu-bar work is compared.
        func growth(_ content: (Int) -> StatusItemRenderer.Content) -> Double {
            renderer.render(content(0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let start = footprintMB()
            for i in 1...3000 {
                renderer.render(content(i))
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return footprintMB() - start
        }
        let control = growth { _ in .init(showsIcon: true, lines: ["40°C", "2300 RPM"]) }
        let updates = growth { i in .init(showsIcon: true, lines: ["\(40 + i % 30)°C", "\(2300 + i % 97) RPM"]) }
        XCTAssertLessThan(updates - control, 1.5,
                          "menu-bar updates leaked \(updates - control) MB over 3,000 updates")
    }

    func testUnchangedContentDoesNotTouchTheMenuBar() {
        let content = StatusItemRenderer.Content(showsIcon: true, lines: ["48°C", "2318 RPM"])
        renderer.render(content)
        let afterFirst = renderer.renderCount
        for _ in 0..<50 { renderer.render(content) }
        XCTAssertEqual(renderer.renderCount, afterFirst)
        renderer.render(.init(showsIcon: true, lines: ["49°C", "2318 RPM"]))
        XCTAssertEqual(renderer.renderCount, afterFirst + 1)
    }

    func testItemWidthFitsWhatItShows() {
        renderer.render(.init(showsIcon: true, lines: []))
        let iconOnly = statusItem.length
        renderer.render(.init(showsIcon: true, lines: ["2318 RPM"]))
        XCTAssertGreaterThan(statusItem.length, iconOnly)
        XCTAssertGreaterThan(iconOnly, 10)
    }

    func testMonitoringFollowsThePopover() {
        let vm = FanControlViewModel()
        vm.startMonitoring()
        XCTAssertTrue(vm.isMonitoring)
        vm.stopMonitoring()
        XCTAssertFalse(vm.isMonitoring)
    }
}
