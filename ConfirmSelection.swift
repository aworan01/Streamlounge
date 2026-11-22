import SwiftUI

/// A tvOS selection control that does not write to its binding while focus moves.
/// The saved value changes ONLY inside the option button's activation closure.
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
    @FocusState private var highlighted: Value?
    @FocusState private var rowFocused: Bool

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? "Not set"
    }

    var body: some View {
        Button { presenting = true } label: {
            HStack(spacing: 16) {
                Text(title).font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 12)
                Image(systemName:"checkmark.circle.fill").foregroundStyle(Color.cyan)
                Text(selectedLabel).font(.system(size: 21,weight:.semibold))
                    .foregroundStyle(Color.cyan)
                    .lineLimit(1).minimumScaleFactor(0.65)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .focused($rowFocused)
        .background(RoundedRectangle(cornerRadius:10).fill(rowFocused ? Color.cyan.opacity(0.22) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(rowFocused ? Color.cyan : Color.clear,lineWidth:4))
        .accessibilityHint("Press Select to choose a value. Moving focus does not change the setting.")
        .sheet(isPresented: $presenting) {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text(title).font(.system(size: 38, weight: .bold))
                    Spacer()
                    Button("Cancel") { presenting = false }
                        .buttonStyle(CompactFocusStyle())
                }
                Text("Move to an option, then press Select to confirm. Press Back to cancel.")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(options) { choice in
                                Button {
                                    // Only the Siri Remote Select/click action commits a choice.
                                    selection = choice.value
                                    presenting = false
                                } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: selection == choice.value ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selection == choice.value ? Color.cyan : Color.secondary)
                                            .frame(width: 34)
                                        Text(choice.label).font(.system(size: 27,weight:selection == choice.value ? .semibold : .regular))
                                            .foregroundStyle(Color.primary)
                                        Spacer(minLength: 8)
                                        if selection == choice.value {Text("SELECTED").font(.caption.bold()).foregroundStyle(Color.cyan)}
                                    }
                                    .padding(.horizontal, 20).padding(.vertical, 15)
                                    .background(RoundedRectangle(cornerRadius: 10)
                                        .fill(highlighted == choice.value ? Color.cyan.opacity(0.28) : (selection == choice.value ? Color.cyan.opacity(0.10) : Color.white.opacity(0.04))))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(highlighted == choice.value ? Color.cyan : (selection == choice.value ? Color.cyan.opacity(0.55) : Color.clear), lineWidth: highlighted == choice.value ? 4 : 2))
                                }
                                .buttonStyle(.bordered)
                                .focused($highlighted, equals: choice.value)
                                .id(choice.value)
                            }
                        }.padding(.vertical, 10)
                    }
                    .onAppear { scroll.scrollTo(selection, anchor: .center) }
                }
                Spacer(minLength: 0)
            }
            .padding(65).frame(maxWidth: 1150, alignment: .leading)
            .onAppear {
                Task { @MainActor in
                    await Task.yield()
                    highlighted = selection
                }
            }
            .onExitCommand { presenting = false }
        }
    }
}
