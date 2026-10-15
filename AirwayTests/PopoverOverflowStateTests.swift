import SwiftUI
import Testing
@testable import Airway

struct PopoverOverflowStateTests {
    @Test func updateChangesOverflowStateSynchronouslyAtTheHeightBoundary() {
        var state = PopoverOverflowState()

        state.update(contentHeight: 501, maxHeight: 500)
        #expect(state.isOverflowing)

        state.update(contentHeight: 500, maxHeight: 500)
        #expect(!state.isOverflowing)
    }
}
