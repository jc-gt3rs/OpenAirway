//
//  PopoverContentHostingController.swift
//
//  Keeps an `NSPopover` the same size as its SwiftUI content on macOS 13.
//
//  From macOS 14, `NSHostingController.sizingOptions = .intrinsicContentSize`
//  wires the two together: SwiftUI reports its ideal size and the popover
//  follows. On Ventura that link does not hold. The popover keeps a content
//  size narrower and shorter than the 320pt-wide content, and `NSPopover`
//  centres the oversized view inside it — so the UI is clipped on all four
//  sides at once: the header vanishes off the top and row labels lose their
//  leading characters ("Add a preset…" reads as "d a preset…").
//
//  This controller closes the loop by hand: after each layout pass it measures
//  the content and pushes that size onto the popover. Attaching a `popover` is
//  what turns the behaviour on, so callers opt in only where it is needed.
//

import SwiftUI

/// The sizing hook, without the hosting controller's generic parameter, so a
/// caller can hold on to the controller and re-measure on demand.
protocol PopoverContentSizing: AnyObject {
    @discardableResult
    func synchronizePopoverContentSize() -> Bool
}

final class PopoverContentHostingController<Content: View>: NSHostingController<Content>, PopoverContentSizing {

    /// The popover to keep in step. Weak because the popover owns this
    /// controller. Leaving it nil disables manual sizing entirely, which is how
    /// macOS 14+ keeps using AppKit's own `.intrinsicContentSize` path.
    weak var popover: NSPopover?

    /// The width the SwiftUI content is pinned to. Height is measured against it.
    var contentWidth: CGFloat = 320

    override func viewDidLayout() {
        super.viewDidLayout()
        synchronizePopoverContentSize()
    }

    /// Resizes the attached popover to fit the content.
    ///
    /// - Returns: `true` if the popover was resized, `false` if it was already
    ///   the right size, there is no popover, or the content has not laid out
    ///   yet.
    @discardableResult
    func synchronizePopoverContentSize() -> Bool {
        guard let popover else { return false }

        let measured = measuredContentSize()
        // A zero measurement means SwiftUI has not laid out yet; adopting it
        // would collapse the popover to nothing.
        guard measured.width > 0, measured.height > 0 else { return false }
        // Assigning `contentSize` triggers another layout pass, which comes
        // straight back here. Without this guard that is an endless loop.
        guard popover.contentSize != measured else { return false }

        popover.contentSize = measured
        return true
    }

    /// The size the content wants: the pinned width, and whatever height the
    /// SwiftUI layout needs at that width.
    func measuredContentSize() -> CGSize {
        let fitting = sizeThatFits(
            in: CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: contentWidth, height: fitting.height.rounded(.up))
    }
}
