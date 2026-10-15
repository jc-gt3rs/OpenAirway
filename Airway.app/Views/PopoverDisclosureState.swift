struct PopoverDisclosureState: Equatable {
    private(set) var isExpanded = false

    mutating func toggle() {
        isExpanded.toggle()
    }
}
