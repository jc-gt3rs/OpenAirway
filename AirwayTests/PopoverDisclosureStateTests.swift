import Testing
@testable import Airway

struct PopoverDisclosureStateTests {
    @Test func toggleUpdatesDisclosureStateSynchronously() {
        var state = PopoverDisclosureState()

        state.toggle()
        #expect(state.isExpanded)

        state.toggle()
        #expect(!state.isExpanded)
    }
}
