//
//  StatusItemRenderer.swift
//
//  Draws Airway's menu-bar item — the fan glyph, the temperature and the
//  fan speed — as Core Animation layers inside the status button.
//
//  The menu-bar item used to be redrawn by building a fresh NSImage every two
//  seconds and assigning it to `button.image`. On macOS 27 every image
//  assignment (and every redraw of a view inside the button) leaves memory
//  behind in the menu bar's observation bookkeeping, which is never freed:
//  about 115 KB per update, which reached ~470 MB after a week and made each
//  later update slower, putting Airway on the battery menu's "Using
//  Significant Energy" list. Changing a CALayer's contents doesn't go
//  through that path at all (measured: no growth over 9,000 updates), so the
//  item is built once and only its layers are touched afterwards — and only
//  when what it shows actually changes.
//

import AppKit

@MainActor
final class StatusItemRenderer {

    /// What the menu-bar item shows. Updates that produce an equal value
    /// don't touch the menu bar at all.
    struct Content: Equatable {
        var showsIcon: Bool
        /// One line ("2318 RPM") or two stacked lines ("48°C" over "2318 RPM").
        var lines: [String]
    }

    private let statusItem: NSStatusItem
    private let canvas = LayerCanvasView()
    private let iconLayer = CALayer()
    private let iconMask = CALayer()
    private let textLayer = CATextLayer()
    private var current: Content?
    private var appearanceObservation: NSKeyValueObservation?
    private var iconSize = NSSize(width: 18, height: 18)

    /// How many times the menu bar was actually changed. For tests.
    private(set) var renderCount = 0

    private static let iconTextGap: CGFloat = 4
    private static let horizontalPadding: CGFloat = 4

    init(statusItem: NSStatusItem, symbolName: String) {
        self.statusItem = statusItem
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""
        button.setAccessibilityLabel("Airway")

        canvas.frame = button.bounds
        canvas.autoresizingMask = [.width, .height]
        button.addSubview(canvas)
        let root = canvas.layer!

        // The glyph is the symbol used as a mask over a solid colour, so it
        // tints like a template image without being re-rendered.
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Airway") {
            iconSize = symbol.size
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            iconMask.contents = symbol.layerContents(forContentsScale: scale)
            iconMask.contentsScale = scale
            iconMask.contentsGravity = .resizeAspect
        }
        iconLayer.mask = iconMask
        root.addSublayer(iconLayer)

        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.alignmentMode = .left
        textLayer.isWrapped = false
        root.addSublayer(textLayer)

        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyColors() }
        }
    }

    /// Shows `content`, doing nothing if it's what the item already shows.
    ///
    /// Only a change of layout (icon on/off, number of lines, length of a
    /// line) resizes the item; ordinary readings just replace the text layer's
    /// string. Resizing a status item costs ~8 KB that macOS 27 never frees
    /// and ~35 ms, so it must stay rare — the width is reserved from the
    /// number of characters, not the digits, so 999 → 1000 RPM is the only
    /// kind of reading that changes it.
    func render(_ content: Content) {
        guard content != current, statusItem.button != nil else { return }
        let layout = Layout(content)
        if layout != currentLayout {
            currentLayout = layout
            applyLayout(layout)
        }
        current = content
        renderCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = content.lines.joined(separator: "\n")
        CATransaction.commit()
        statusItem.button?.setAccessibilityValue(content.lines.joined(separator: ", "))
    }

    /// The shape of the item: what decides its size and where things sit.
    private struct Layout: Equatable {
        var showsIcon: Bool
        var lineLengths: [Int]
        init(_ content: Content) {
            showsIcon = content.showsIcon
            lineLengths = content.lines.map(\.count)
        }
    }

    private var currentLayout: Layout?

    private func applyLayout(_ layout: Layout) {
        guard let button = statusItem.button else { return }
        let stacked = layout.lineLengths.count > 1
        let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9.5 : 11, weight: .medium)
        // Monospaced digits: a template of the same length measures any reading.
        let template = layout.lineLengths.map { String(repeating: "8", count: $0) }.joined(separator: "\n")
        let textSize = layout.lineLengths.isEmpty
            ? .zero
            : NSAttributedString(string: template, attributes: [.font: font]).size()

        let iconWidth = layout.showsIcon ? iconSize.width : 0
        let gap = layout.showsIcon && !layout.lineLengths.isEmpty ? Self.iconTextGap : 0
        let width = ceil(Self.horizontalPadding * 2 + iconWidth + gap + textSize.width)
        if statusItem.length != width { statusItem.length = width }

        let height = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.isHidden = !layout.showsIcon
        iconLayer.frame = CGRect(x: Self.horizontalPadding, y: (height - iconSize.height) / 2,
                                 width: iconSize.width, height: iconSize.height)
        iconMask.frame = iconLayer.bounds
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.frame = CGRect(x: Self.horizontalPadding + iconWidth + gap,
                                 y: (height - ceil(textSize.height)) / 2,
                                 width: ceil(textSize.width) + 2, height: ceil(textSize.height))
        CATransaction.commit()
        applyColors()
    }

    /// Tints the glyph and text for the menu bar's current appearance.
    private func applyColors() {
        guard let button = statusItem.button else { return }
        let color = Self.textColor(for: button).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.backgroundColor = color
        textLayer.foregroundColor = color
        CATransaction.commit()
    }

    private static func textColor(for button: NSView) -> NSColor {
        var resolved = NSColor.labelColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }
        return resolved
    }
}

/// A layer-backed view that never draws itself; it only hosts sublayers.
private final class LayerCanvasView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    // Clicks go to the status button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
