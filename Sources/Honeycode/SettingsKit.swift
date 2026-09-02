import SwiftUI

// The settings panes, in the app's own kit rather than AppKit's.
//
// Every pane in Settings was a `Form` with `.formStyle(.grouped)`, and that is
// the one control in this app that arrives with a design of its own. It paints
// two greys — a form ground and a section box — and neither of them is
// `Theme.canvas` or `Theme.surface`. It sets section headers at display size,
// two steps above `Theme.title`, six or seven to a pane. It draws its own
// hairlines, its own corner radius and its own row insets, none of which are
// on this app's scales. And it promotes a `TextField`'s first argument to a
// leading label, which turned a placeholder in Crew & Safety into a two-line
// monospace caption beside an empty field.
//
// So Settings was the only pane in the window not made of the same parts as
// the rest of it, and it read that way: a lighter rectangle floating on the
// pane with a hard edge down each side, headings shouting, and three different
// sizes of explanatory text across six tabs.
//
// These four types are what the `Form` was doing, drawn from `Theme`:
//
// - `SettingsPage`  — the scroll, the measure, the rhythm between groups.
// - `SettingsGroup` — a title, a card of rows, a footnote under it.
// - `SettingsRow`   — a label, a line about it, and a control.
// - `SettingsToggle`— that row with a switch, which is most of them.
//
// There is no `SettingsSlider` or `SettingsPicker`: a row takes any control,
// and naming one type per AppKit control is how a kit turns into a catalogue.

/// One pane's worth of settings: the scroll, the measure and the rhythm.
///
/// The measure is `Theme.readingWidth`, the same one the transcript is set to,
/// and that is the point of it. Settings had a measure of its own — 640, the
/// width of the window it used to be — while the tab strip above it ran the
/// full width of the pane. The result was a header and a body in two different
/// columns with no shared edge, which is the same fault the start pane had and
/// was fixed for the same reason. One measure, one left edge, everything on it.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    /// Where the column starts, handed down by `SettingsPane`.
    @Environment(\.settingsInset) private var inset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s7) {
                content()
            }
            .frame(maxWidth: SettingsMetrics.measure, alignment: .leading)
            .padding(.leading, inset)
            .padding(.trailing, Theme.s6)
            .padding(.top, Theme.s6)
            // Deeper at the foot than the head: a scroll that ends flush with
            // the window edge reads as cut off rather than finished.
            .padding(.bottom, Theme.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum SettingsMetrics {
    /// The transcript's measure, and Settings' too. See `SettingsPage`.
    static let measure = Theme.readingWidth

    /// Where the column starts.
    ///
    /// Measured on the *pane* and pushed into the environment rather than
    /// worked out by each page, because a page is inside a `ScrollView` and a
    /// scroll view is 15pt narrower than the pane whenever the scrollers are
    /// set to Always. Both halves centring in their own idea of the available
    /// width put the cards half a scroller left of the tab strip above them —
    /// on the tabs that scroll, and only those, which is worse than a
    /// consistent offset would have been.
    static func inset(for width: CGFloat) -> CGFloat {
        max(Theme.s6, (width - measure) / 2)
    }
}

private struct SettingsInsetKey: EnvironmentKey {
    static let defaultValue = Theme.s6
}

extension EnvironmentValues {
    var settingsInset: CGFloat {
        get { self[SettingsInsetKey.self] }
        set { self[SettingsInsetKey.self] = newValue }
    }
}

/// A titled card of rows, with an optional footnote under it.
///
/// The footnote sits *outside* the card deliberately. In the old panes an
/// explanation was a row like any other — same box, same height, same insets —
/// so a two-line paragraph about a switch read as a second switch that had
/// failed to draw its control.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            if let title {
                Text(title)
                    .font(Theme.title)
                    .foregroundStyle(.secondary)
            }
            card
            if let footer {
                Text(footer)
                    // `.secondary`, not `.tertiary`, and this is the floor
                    // `Theme` states rather than a preference: a footnote is
                    // the only place its sentence appears on screen.
                    .font(Theme.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.s1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerCard)
        return VStack(spacing: 0) { content() }
            // Every row draws a hairline under itself, which leaves one too
            // many: the last row's would sit a point above the card's own
            // bottom edge. Pulling the stack down by a point puts that last
            // hairline outside the clip, so it is never drawn rather than
            // drawn and then covered — and no row has to know whether it is
            // the last one, which is the thing a `Form` needs a variadic view
            // to work out.
            .padding(.bottom, -1)
            .clipShape(shape)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.rule, lineWidth: 1))
            .modifier(Elevated(depth: .low))
    }
}

/// One row: a label, a line about it, and a control.
///
/// The control is on the trailing edge, always. Accounts put its switches on
/// the leading edge and every other pane put them on the trailing one, so two
/// adjacent tabs had two ideas of what a settings row looks like.
struct SettingsRow<Control: View>: View {
    var label: String?
    var note: String?
    /// An organisation is holding this one. Draws a lock beside the label
    /// rather than a sentence in a row below it — the lock belongs on the
    /// control it governs, and a row of its own was one more thing in the box
    /// that wasn't a setting.
    var locked = false
    @ViewBuilder let control: () -> Control

    init(_ label: String? = nil, note: String? = nil, locked: Bool = false,
         @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.note = note
        self.locked = locked
        self.control = control
    }

    var body: some View {
        HStack(spacing: Theme.s5) {
            if label != nil || note != nil {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    if let label {
                        HStack(spacing: Theme.s2) {
                            Text(label).font(Theme.sidebarRow)
                            if locked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: Theme.t1))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let note {
                        Text(note)
                            .font(Theme.note)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A clear gutter before the control. A note that runs to
                // within a hair of a switch reads as a caption on it.
                Spacer(minLength: Theme.s7)
            }
            control()
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
        .help(locked ? Policy.note : "")
    }
}

/// The row most of Settings is made of.
struct SettingsToggle: View {
    let label: String
    var note: String?
    var locked = false
    @Binding var isOn: Bool

    init(_ label: String, note: String? = nil, locked: Bool = false,
         isOn: Binding<Bool>) {
        self.label = label
        self.note = note
        self.locked = locked
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(label, note: note, locked: locked) {
            // Said explicitly, because outside a `Form` macOS draws a `Toggle`
            // as a checkbox. Every switch in Settings was a switch until these
            // panes stopped being forms, and a checkbox is a different promise:
            // it reads as one of several things you are picking, not as a thing
            // that is on.
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(locked)
        }
    }
}

/// A row of buttons and nothing else — the actions at the foot of a group.
struct SettingsActions<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        SettingsRow {
            HStack(spacing: Theme.s4) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
