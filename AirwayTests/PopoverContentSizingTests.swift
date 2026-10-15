//
//  PopoverContentSizingTests.swift
//
//  Covers the manual popover sizing Ventura needs, where `NSPopover` does not
//  follow an `NSHostingController`'s `.intrinsicContentSize`.
//

import XCTest
import SwiftUI
@testable import Airway

@MainActor
final class PopoverContentSizingTests: XCTestCase {

    private func makeController(width: CGFloat, height: CGFloat) -> PopoverContentHostingController<AnyView> {
        let controller = PopoverContentHostingController(
            rootView: AnyView(Color.clear.frame(width: width, height: height))
        )
        controller.contentWidth = width
        return controller
    }

    func testResizesTheAttachedPopoverToTheContent() {
        let controller = makeController(width: 320, height: 240)
        let popover = NSPopover()
        controller.popover = popover

        XCTAssertTrue(controller.synchronizePopoverContentSize())
        XCTAssertEqual(popover.contentSize.width, 320)
        XCTAssertEqual(popover.contentSize.height, 240)
    }

    /// The resize triggers another layout pass, which calls back in. Without a
    /// no-op on the second call that is an endless loop.
    func testDoesNotResizeAPopoverThatIsAlreadyTheRightSize() {
        let controller = makeController(width: 320, height: 240)
        let popover = NSPopover()
        controller.popover = popover

        XCTAssertTrue(controller.synchronizePopoverContentSize())
        XCTAssertFalse(controller.synchronizePopoverContentSize())
        XCTAssertFalse(controller.synchronizePopoverContentSize())
    }

    /// macOS 14+ leaves `popover` nil and keeps AppKit's own sizing path.
    func testDoesNothingWithoutAnAttachedPopover() {
        let controller = makeController(width: 320, height: 240)
        XCTAssertFalse(controller.synchronizePopoverContentSize())
    }

    func testMeasuresContentAtThePinnedWidth() {
        let controller = makeController(width: 320, height: 180)
        let measured = controller.measuredContentSize()

        XCTAssertEqual(measured.width, 320, "Width is pinned, never measured.")
        XCTAssertEqual(measured.height, 180)
    }

    /// Taller content must widen nothing and lengthen the popover.
    func testTrackedHeightFollowsTheContent() {
        let short = makeController(width: 320, height: 120)
        let tall = makeController(width: 320, height: 420)

        XCTAssertEqual(short.measuredContentSize().width, tall.measuredContentSize().width)
        XCTAssertLessThan(short.measuredContentSize().height, tall.measuredContentSize().height)
    }
}
