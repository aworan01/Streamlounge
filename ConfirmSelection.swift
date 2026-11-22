import SwiftUI

/// A tvOS selection control whose bound value changes only when Select is pressed.
/// Moving Siri Remote focus never writes to the settings binding.
struct ConfirmOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }

    init(_ value: Value, _ label: String) {
        self.value = value
        self.label = label
    }
}

struct ConfirmSelection<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [ConfirmOption<Value>]

    @State private var presenting = false
    @FocusState private var rowFocused: Bool

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? "Not set"
    }

    var body: some View {
        Button {
            presenting = true
        } label: {
            ConfirmSelectionSummary(title: title,
                                    selectedLabel: selectedLabel,
                                    isFocused: rowFocused)
        }
        .buttonStyle(ManualFocusStyle())
        .focused($rowFocused)
        .accessibilityLabel("\(title), \(selectedLabel)")
        .accessibilityHint("Press Select to choose a value. Focus does not change settings.")
        .sheet(isPresented: $presenting) {
            ConfirmSelectionPanel(title: title,
                                  selection: $selection,
                                  options: options,
                                  isPresented: $presenting)
        }
    }
}

/// Split from the generic selection view to keep SwiftUI's type-checker fast.
private struct ConfirmSelectionSummary: View {
    let title: String
    let selectedLabel: String
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 12)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.cyan)
            Text(selectedLabel)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isFocused ? Color.cyan.opacity(0.22) : Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isFocused ? Color.cyan : Color.clear, lineWidth: 4)
        )
    }
}

private struct ConfirmSelectionPanel<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [ConfirmOption<Value>]
    @Binding var isPresented: Bool

    @FocusState private var focusedChoice: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading
            Text("Move to an option, then press Select to confirm. Press Back to cancel.")
                .font(.system(size: 19))
                .foregroundStyle(Color.secondary)
            choices
            Spacer(minLength: 0)
        }
        .padding(65)
        .frame(maxWidth: 1150, alignment: .leading)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedChoice = selection
            }
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private var heading: some View {
        HStack {
            Text(title)
                .font(.system(size: 38, weight: .bold))
            Spacer()
            Button("Cancel") {
                isPresented = false
            }
            .buttonStyle(CompactFocusStyle())
        }
    }

    private var choices: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(options) { choice in
                        optionButton(choice)
                            .id(choice.value)
                    }
                }
                .padding(.vertical, 10)
            }
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    private func optionButton(_ option: ConfirmOption<Value>) -> some View {
        Button {
            // The binding changes ONLY on the remote's Select/click activation.
            selection = option.value
            isPresented = false
        } label: {
            ConfirmSelectionChoiceRow(label: option.label,
                                      isSelected: selection == option.value,
                                      isFocused: focusedChoice == option.value)
        }
        .buttonStyle(ManualFocusStyle())
        .focused($focusedChoice, equals: option.value)
    }
}

private struct ConfirmSelectionChoiceRow: View {
    let label: String
    let isSelected: Bool
    let isFocused: Bool

    private var fillColor: Color {
        if isFocused { return Color.cyan.opacity(0.28) }
        if isSelected { return Color.cyan.opacity(0.10) }
        return Color.white.opacity(0.04)
    }

    private var outlineColor: Color {
        if isFocused { return Color.cyan }
        if isSelected { return Color.cyan.opacity(0.55) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.cyan : Color.secondary)
                .frame(width: 34)
            Text(label)
                .font(.system(size: 27, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            if isSelected {
                Text("SELECTED")
                    .font(.caption.bold())
                    .foregroundStyle(Color.cyan)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: 10).fill(fillColor))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(outlineColor, lineWidth: isFocused ? 4 : 2))
        .contentShape(Rectangle())
    }
}
