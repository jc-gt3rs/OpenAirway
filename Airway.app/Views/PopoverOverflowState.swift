import CoreGraphics

struct PopoverOverflowState: Equatable {
    private(set) var isOverflowing = false

    mutating func update(contentHeight: CGFloat, maxHeight: CGFloat) {
        isOverflowing = contentHeight > maxHeight
    }
}
