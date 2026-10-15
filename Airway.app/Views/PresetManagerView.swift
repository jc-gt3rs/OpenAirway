//
//  PresetManagerView.swift
//  
//
//  Created by John Cris Antor on 6/21/2026.
//

import SwiftUI

struct PresetManagerView: View {
    @ObservedObject var viewModel: FanControlViewModel
    @ObservedObject private var loc = LocalizationManager.shared

    @State private var selectedPresetID: UUID?
    @State private var editingName: String = ""
    @State private var editingMode: PresetMode = .percentage
    @State private var editingValue: Int = 50
    @State private var editingSymbol: String = ""
    @State private var isCreatingNew = false
    @State private var errorMessage: String?
    @State private var showingSymbolPicker = false

    private var selectedPreset: Preset? {
        guard let selectedPresetID else { return nil }
        return viewModel.presetStore.presets.first { $0.id == selectedPresetID }
    }

    private var hasUnsavedChanges: Bool {
        if isCreatingNew { return true }
        guard let preset = selectedPreset else { return false }
        
        let trimmedName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSymbol = editingSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSymbol = normalizedSymbol(trimmedSymbol)
        
        return preset.name != trimmedName ||
               preset.symbol != finalSymbol ||
               preset.mode != editingMode ||
               preset.value != editingValue
    }

    private var canSave: Bool {
        errorMessage == nil && !editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasUnsavedChanges
    }

    private var isEditing: Bool {
        isCreatingNew || selectedPreset != nil
    }

    private var valueRange: ClosedRange<Int> {
        switch editingMode {
        case .percentage:
            return 25...100
        case .rpm:
            let minRPM = Int(viewModel.fans.map(\.minRPM).min() ?? 0)
            let maxRPM = Int(viewModel.fans.map(\.maxRPM).max() ?? 6000)
            return minRPM...max(maxRPM, minRPM)
        }
    }

    private var valueStep: Int {
        editingMode == .percentage ? 5 : 100
    }

    private var valueUnit: String {
        editingMode == .percentage ? "%" : "RPM"
    }

    private var detailTitle: String {
        if isCreatingNew { return loc.t("preset_new") }
        return selectedPreset?.name ?? loc.t("preset_sidebar_title")
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            detailPane
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 430, idealHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: selectInitialPresetIfNeeded)
        .onChange(of: selectedPresetID) { newID in
            if let newID, let preset = viewModel.presetStore.presets.first(where: { $0.id == newID }) {
                loadPresetForEditing(preset)
            } else if newID == nil && !isCreatingNew {
                clearEditor()
            }
        }
        .onChange(of: viewModel.presetStore.presets) { presets in
            guard let selectedPresetID, presets.contains(where: { $0.id == selectedPresetID }) else {
                if !isCreatingNew {
                    selectedPresetID = presets.first?.id
                }
                return
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(loc.t("preset_sidebar_title"))
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if viewModel.presetStore.presets.isEmpty && !isCreatingNew {
                PresetSidebarEmptyView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(viewModel.presetStore.presets) { preset in
                            PresetSidebarRow(
                                preset: preset,
                                isSelected: selectedPresetID == preset.id && !isCreatingNew,
                                valueText: formatValue(preset.value, mode: preset.mode),
                                action: { selectPreset(preset) },
                                deleteAction: { deletePreset(preset) }
                            )
                        }
                        if isCreatingNew {
                            PresetSidebarRow(
                                preset: Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: editingName.isEmpty ? loc.t("preset_new") : editingName, mode: editingMode, value: editingValue, symbol: normalizedSymbol(editingSymbol.trimmingCharacters(in: .whitespacesAndNewlines))),
                                isSelected: true,
                                valueText: formatValue(editingValue, mode: editingMode),
                                action: {},
                                deleteAction: {
                                    isCreatingNew = false
                                    selectedPresetID = viewModel.presetStore.presets.first?.id
                                    if selectedPresetID == nil { clearEditor() }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            Divider()

            HStack(spacing: 6) {
                Button(action: startNewPreset) {
                    Label(loc.t("preset_add"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(loc.t("preset_add_help"))

                Button(action: deleteSelectedPreset) {
                    Label(loc.t("preset_delete"), systemImage: "minus")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(selectedPreset == nil || isCreatingNew)
                .help(loc.t("preset_delete_help"))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 236)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detailTitle)
                            .font(.title3)
                            .bold()
                            .lineLimit(1)

                        Text(formatValue(editingValue, mode: editingMode))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(loc.t("preset_save"), action: saveCurrentState)
                        .font(.system(size: 13, weight: .medium))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)

                Divider()
            }

            if isEditing {
                editor
            } else {
                PresetDetailEmptyView(action: startNewPreset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent(loc.t("preset_name_label")) {
                TextField(loc.t("preset_name_placeholder"), text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onChange(of: editingName) { _ in validateCurrentState() }
                    .onSubmit(saveCurrentState)
            }

            LabeledContent(loc.t("preset_icon_label")) {
                Button {
                    showingSymbolPicker = true
                } label: {
                    HStack(spacing: 8) {
                        presetIcon(symbol: editingSymbol, size: 26, selected: false)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 86, height: 32, alignment: .leading)
                    
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingSymbolPicker, arrowEdge: .trailing) {
                    SymbolPickerPopover(selectedSymbol: $editingSymbol)
                }
            }

            LabeledContent(loc.t("preset_type_label")) {
                PresetModeSegmentedControl(selection: $editingMode)
                .frame(width: 220)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: editingMode) { _ in handleModeChange() }
            }

            LabeledContent(loc.t("preset_value_label")) {
                HStack(spacing: 5) {
                    TextField(valueUnit, value: $editingValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 86)
                        .onChange(of: editingValue) { _ in validateCurrentState() }
                        .onSubmit(saveCurrentState)

                    Stepper(loc.t("preset_value_label"), value: $editingValue, in: valueRange, step: valueStep)
                        .labelsHidden()

                    Text(valueUnit)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 34, alignment: .leading)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .padding(.top, 2)
            } else {
                Text(valueHelpText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }

            Spacer()
        }
        .labeledContentStyle(PresetEditorLabeledContentStyle())
        .padding(24)
    }

    private var valueHelpText: String {
        switch editingMode {
        case .percentage:
            return loc.t("preset_range_percentage")
        case .rpm:
            return loc.t("preset_range_rpm", valueRange.lowerBound, valueRange.upperBound)
        }
    }

    private func formatValue(_ value: Int, mode: PresetMode) -> String {
        switch mode {
        case .percentage: return "\(value)%"
        case .rpm: return "\(value) RPM"
        }
    }

    private func selectInitialPresetIfNeeded() {
        guard selectedPresetID == nil, !isCreatingNew else { return }
        selectedPresetID = viewModel.presetStore.presets.first?.id
    }

    private func selectPreset(_ preset: Preset) {
        isCreatingNew = false
        selectedPresetID = preset.id
    }

    private func startNewPreset() {
        isCreatingNew = true
        selectedPresetID = nil
        editingName = loc.t("preset_new")
        editingSymbol = ""
        editingMode = .percentage
        editingValue = 50
        validateCurrentState()
    }

    private func loadPresetForEditing(_ preset: Preset) {
        isCreatingNew = false
        editingName = preset.name
        editingSymbol = preset.symbol ?? ""
        editingMode = preset.mode
        editingValue = preset.value
        validateCurrentState()
    }

    private func clearEditor() {
        editingName = ""
        editingSymbol = ""
        editingMode = .percentage
        editingValue = 50
        errorMessage = nil
    }

    private func handleModeChange() {
        let range = valueRange
        if !range.contains(editingValue) {
            editingValue = editingMode == .percentage ? 50 : range.lowerBound
        }
        validateCurrentState()
    }

    private func validateCurrentState() {
        if let nameError = PresetStore.validateName(editingName) {
            errorMessage = nameError
            return
        }

        let minRPM = Double(valueRange.lowerBound)
        let maxRPM = Double(valueRange.upperBound)

        if let valueError = PresetStore.validateValue(editingValue, mode: editingMode, minRPM: minRPM, maxRPM: maxRPM) {
            errorMessage = valueError
            return
        }

        errorMessage = nil
    }

    private func saveCurrentState() {
        validateCurrentState()
        guard canSave else { return }

        let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = editingSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSymbol = normalizedSymbol(symbol)

        if isCreatingNew {
            let newPreset = Preset(name: name, mode: editingMode, value: editingValue, symbol: finalSymbol)
            viewModel.presetStore.addPreset(newPreset)
            isCreatingNew = false
            selectedPresetID = newPreset.id
        } else if let id = selectedPresetID {
            let updatedPreset = Preset(id: id, name: name, mode: editingMode, value: editingValue, symbol: finalSymbol)
            viewModel.presetStore.updatePreset(updatedPreset)
        }
    }

    private func deleteSelectedPreset() {
        guard let preset = selectedPreset else { return }
        deletePreset(preset)
    }

    private func deletePreset(_ preset: Preset) {
        let wasSelected = selectedPresetID == preset.id
        viewModel.presetStore.deletePreset(preset)

        if wasSelected {
            selectedPresetID = viewModel.presetStore.presets.first?.id
            if selectedPresetID == nil {
                clearEditor()
            }
        }
    }

    private func normalizedSymbol(_ symbol: String) -> String? {
        guard !symbol.isEmpty else { return nil }
        if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            return symbol
        }
        return String(symbol.prefix(1))
    }

    @ViewBuilder
    private func presetIcon(symbol: String?, size: CGFloat, selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? Color.accentColor : Color(nsColor: .controlColor))
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(selected ? 0 : 0.08), lineWidth: 1)
                )

            if let symbol, !symbol.isEmpty {
                if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.48, weight: .medium))
                        .foregroundColor(selected ? .white : .primary.opacity(0.82))
                } else {
                    Text(symbol)
                        .font(.system(size: size * 0.44))
                        .foregroundColor(selected ? .white : .primary)
                }
            } else {
                Image(systemName: AirwaySymbol.fan.resolved)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundColor(selected ? .white : .primary.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
    }
}

private struct PresetSidebarRow: View {
    let preset: Preset
    let isSelected: Bool
    let valueText: String
    let action: () -> Void
    let deleteAction: () -> Void
    @ObservedObject private var loc = LocalizationManager.shared

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                presetIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text(valueText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(isSelected ? .white.opacity(0.78) : .secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(rowBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(role: .destructive, action: deleteAction) {
                Label(loc.t("preset_delete_context"), systemImage: "trash")
            }
        }
        .accessibilityValue(isSelected ? loc.t("preset_selected_a11y") : "")
    }

    private var rowBackground: Color {
        if isSelected { return .accentColor }
        if isHovered { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var presetIcon: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.white.opacity(0.22) : Color(nsColor: .controlColor))
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.08), lineWidth: 1)
                )

            if let symbol = preset.symbol, !symbol.isEmpty {
                if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? .white : .primary.opacity(0.82))
                } else {
                    Text(symbol)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .white : .primary)
                }
            } else {
                Image(systemName: AirwaySymbol.fan.resolved)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary.opacity(0.82))
            }
        }
        .frame(width: 28, height: 28)
    }
}

private struct PresetSidebarEmptyView: View {
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        Text(loc.t("preset_nothing_to_show"))
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(.secondary)
        .padding(18)
    }
}

private struct PresetDetailEmptyView: View {
    let action: () -> Void
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 14) {
            Text(loc.t("preset_none_yet"))
                .font(.headline)

            Button(loc.t("preset_new"), action: action)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(24)
    }
}

private struct PresetModeSegmentedControl: View {
    @Binding var selection: PresetMode
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 4) {
            segment(loc.t("preset_percentage"), mode: .percentage)
            segment(loc.t("preset_rpm"), mode: .rpm)
        }
        .padding(2)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    private func segment(_ title: String, mode: PresetMode) -> some View {
        Button {
            selection = mode
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(selection == mode ? .white : .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selection == mode ? Color.accentColor : Color.primary.opacity(0.08))
        )
    }
}

private struct PresetEditorLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            configuration.label
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .trailing)

            configuration.content
        }
    }
}

struct SymbolPickerPopover: View {
    @Binding var selectedSymbol: String
    @Environment(\.dismiss) var dismiss
    @FocusState private var emojiFieldIsFocused: Bool
    @State private var emojiInput = ""
    @ObservedObject private var loc = LocalizationManager.shared

    private struct SymbolSection: Identifiable {
        let id: String
        let symbols: [String]
    }

    // Each catalogue spans several SF Symbols releases, so it goes through
    // `AirwaySymbol.renderable` — anything the running macOS has never heard of
    // would otherwise be a blank, unpickable tile.
    private let sections = [
        SymbolSection(
            id: "Airflow",
            symbols: AirwaySymbol.renderable([
                "fan.fill", "fan.slash", "fan.slash.fill", "fan.desk", "fan.desk.fill",
                "fan.ceiling", "fan.ceiling.fill", "fan.floor", "fan.floor.fill",
                "fan.oscillation", "fan.oscillation.fill", "wind", "wind.snow",
                "snowflake", "thermometer.sun", "thermometer.snowflake", "flame"
            ])
        ),
        SymbolSection(
            id: "Devices",
            symbols: AirwaySymbol.renderable([
                "laptopcomputer", "desktopcomputer", "display", "macpro.gen1",
                "macpro.gen2", "macpro.gen3", "macmini", "macstudio", "cpu",
                "memorychip", "internaldrive", "externaldrive", "powerplug",
                "battery.100percent", "bolt.fill", "gauge.with.dots.needle.50percent"
            ])
        ),
        SymbolSection(
            id: "People",
            symbols: AirwaySymbol.renderable([
                "person.fill", "person.2.fill", "person.crop.circle", "figure.stand",
                "figure.walk", "figure.run", "figure.cooldown", "figure.core.training",
                "face.smiling", "eye.fill", "eyes", "ear.fill", "hand.raised.fill",
                "hand.thumbsup.fill", "hand.thumbsdown.fill", "hand.tap.fill"
            ])
        ),
        SymbolSection(
            id: "Objects",
            symbols: AirwaySymbol.renderable([
                "headphones", "speaker.wave.3.fill", "music.note", "music.note.list",
                "gamecontroller.fill", "keyboard", "sparkles",
                "wand.and.stars", "slider.horizontal.3", "dial.low", "dial.medium",
                "dial.high", "speedometer", "timer", "stopwatch.fill"
            ])
        )
    ]

    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 13), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            preview

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(loc.t("symbol_category_\(section.id.lowercased())"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.72))

                            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                ForEach(section.symbols, id: \.self) { symbol in
                                    iconButton(symbol)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .frame(width: 352, height: 360)

            Divider()

            HStack(spacing: 8) {
                Button {
                    selectedSymbol = ""
                    emojiInput = ""
                } label: {
                    Text(loc.t("symbol_clear"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SymbolPickerFooterButtonStyle())

                Button {
                    emojiInput = ""
                    emojiFieldIsFocused = true
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Label(loc.t("symbol_emoji"), systemImage: "face.smiling")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SymbolPickerFooterButtonStyle())

            }
            .overlay(alignment: .leading) {
                TextField("", text: $emojiInput)
                    .focused($emojiFieldIsFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .padding(8)
            .background(.thinMaterial)
        }
        .background(.regularMaterial)
        .onChange(of: emojiInput) { newValue in
            let symbol = normalizedSymbol(newValue)
            guard !symbol.isEmpty else { return }
            selectedSymbol = symbol
            emojiInput = symbol
        }
    }

    private var preview: some View {
        VStack(spacing: 14) {
            currentSymbolView(size: 62)
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.secondary)
                .frame(width: 104, height: 82)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
    }

    private func normalizedSymbol(_ symbol: String) -> String {
        let trimmedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if NSImage(systemSymbolName: trimmedSymbol, accessibilityDescription: nil) != nil {
            return trimmedSymbol
        }
        return String(trimmedSymbol.prefix(1))
    }

    private func iconButton(_ symbol: String) -> some View {
        Button {
            selectedSymbol = symbol
        } label: {
            ZStack {
                if selectedSymbol == symbol {
                    Circle()
                        .fill(Color(nsColor: .controlAccentColor).opacity(0.12))
                        .overlay(
                            Circle()
                                .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 3)
                        )
                        .frame(width: 52, height: 52)
                }

                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(selectedSymbol == symbol ? Color(nsColor: .controlAccentColor) : .secondary)
                    .frame(width: 52, height: 52)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .help(symbol)
    }

    @ViewBuilder
    private func currentSymbolView(size: CGFloat) -> some View {
        let symbol = selectedSymbol.isEmpty ? AirwaySymbol.fan.resolved : selectedSymbol

        if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
        } else {
            Text(symbol)
                .font(.system(size: size))
        }
    }
}

private struct SymbolPickerFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.primary.opacity(0.82))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlColor).opacity(configuration.isPressed ? 0.72 : 0.48))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
    }
}
