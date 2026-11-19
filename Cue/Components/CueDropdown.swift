import SwiftUI

/// One option in a `CueDropdown`. `value` is the stable identity written back
/// on selection; `label` is what the user sees.
struct CueDropdownOption: Identifiable, Equatable {
    let value: String
    let label: String
    var id: String { value }
    init(_ value: String, _ label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }
}

/// A dropdown selector matching the APK's pickers: a focusable trigger card
/// showing the current value; pressing it opens a full-screen list of every
/// option (each focus-highlighted, the current one check-marked), and picking
/// one writes it back and closes. Fully Siri-remote driven — no hover/tap.
///
/// Two trigger looks:
/// - `triggerWidth != nil` → compact filter style (small label on top, big
///   value below, fixed width), used for Library Type/Sort.
/// - `triggerWidth == nil` → settings-row style: `[icon]` title (+ subtitle)
///   … value ▾, full width. Used for TMDB language, Playback rows, etc.
struct CueDropdown: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    let selection: String
    let options: [CueDropdownOption]
    var triggerWidth: CGFloat? = nil
    let onSelect: (String) -> Void

    @State private var open = false

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? selection
    }

    var body: some View {
        Button { open = true } label: {
            DropdownTrigger(title: title, subtitle: subtitle, icon: icon, value: currentLabel, width: triggerWidth)
        }
        .buttonStyle(PlainCardButtonStyle())
        .fullScreenCover(isPresented: $open) {
            DropdownPicker(title: title, selection: selection, options: options,
                           onSelect: { onSelect($0); open = false },
                           onCancel: { open = false })

        }
    }
}

private struct DropdownTrigger: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    var subtitle: String?
    var icon: String?
    let value: String
    var width: CGFloat?

    private var compact: Bool { width != nil }

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: CueSpacing.md) {
            if let icon, !compact {
                SettingsIconTile(symbol: icon)
            }
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                if compact {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundStyle(CuePalette.textTertiary)
                    Text(value)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(CuePalette.textPrimary)
                } else {
                    Text(title)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(CuePalette.textPrimary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 20))
                            .foregroundStyle(CuePalette.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: CueSpacing.sm)
            if !compact {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CuePalette.secondary)
                    .padding(.top, 2)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(CuePalette.textSecondary)
                .padding(.top, compact ? 0 : 2)
        }
        .padding(.horizontal, compact ? CueSpacing.lg : CueSpacing.md)
        .padding(.vertical, compact ? 0 : CueSpacing.md)
        .frame(width: width, height: compact ? 84 : nil)
        .frame(minHeight: compact ? nil : 74)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(dropdownBackground)
        .overlay {
            if compact {
                RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                    .strokeBorder(isFocused ? Color.white.opacity(0.9) : .clear, lineWidth: 3)
            }
        }
        .shadow(color: compact && isFocused ? .black.opacity(0.35) : .clear,
                radius: compact && isFocused ? 18 : 0, y: 8)
        .focusLift(compact ? CueFocus.row : 1.0, isFocused)
    }

    // Compact (player panels / Discover / Library) keeps a solid pill fill so it
    // reads as a control on its own. In Settings the trigger is flat inside a
    // group card and only lights up on focus, matching the other rows.
    @ViewBuilder
    private var dropdownBackground: some View {
        if compact {
            // The flat control's rest (it's in the page); focus is the
            // bright ring + lift.
            RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous).fill(FlatControl.rest)
        } else {
            SettingsRowBackground(isFocused: isFocused)
        }
    }
}

/// The full-screen option list. Initial focus lands on the current selection.
struct DropdownPicker: View {
    let title: String
    let selection: String
    let options: [CueDropdownOption]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: String?

    /// The band between the title and the first row that scrolled options
    /// dissolve into. Exactly the gap the title and the list used to be
    /// separated by, so nothing moves — the space is just painted now.
    private static let headerFade = CueSpacing.xl

    /// The title on the page, in its ink.
    private var header: some View {
        Text(title)
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(CueInk.primary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Self.headerFade)
    }

    var body: some View {
        ZStack {
            ATVBackground().ignoresSafeArea()
            // `spacing: 0`: the gap that used to be here is now the header's
            // own bottom padding, which is what the fade is drawn over.
            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: CueSpacing.sm) {
                        ForEach(options) { option in
                            Button { onSelect(option.value) } label: {
                                DropdownOptionRow(label: option.label, selected: option.value == selection)
                            }
                            .buttonStyle(PlainCardButtonStyle())
                            .focused($focused, equals: option.value)
                        }
                    }
                    // Room for the focus ring + scale so rows aren't clipped
                    // at the scroll view's edges.
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: 800, maxHeight: 760)
            }
            .padding(CueSpacing.huge)
        }
        .onExitCommand { onCancel() }
        .onAppear { focused = selection }
    }
}

private struct DropdownOptionRow: View {
    @Environment(\.isFocused) private var isFocused
    let label: String
    let selected: Bool

    var body: some View {
        let ink = isFocused ? FlatControl.contentOnFocus : FlatControl.content
        HStack {
            Text(label)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(ink)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ink)
            }
        }
        .padding(.horizontal, CueSpacing.lg)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: CueRadius.md, style: .continuous)
                .fill(isFocused ? FlatControl.focus : selected ? FlatControl.selected : FlatControl.rest)
        )
        .scaleEffect(isFocused ? 1.03 : 1)
        .animation(FlatControl.focusChange, value: isFocused)
    }
}
