import SwiftUI
import AppKit

// MARK: - Payload from the clipboard

extension Relay {
    /// Whatever you last copied.
    ///
    /// The transcript renders through a custom Markdown view using SwiftUI's
    /// `.textSelection(.enabled)`, and SwiftUI offers no way to read that
    /// selection — no binding, and no hook into its context menu. So selecting
    /// a passage and sending it is select, ⌘C, ⌘⇧S. The picker names what it
    /// found, so it's never a guess about what's about to travel.
    static func payloadFromClipboard() throws -> Payload {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Refusal.empty
        }
        let head = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let summary = head.count > 40 ? String(head.prefix(40)) + "…" : head
        return Payload(label: "Clipboard — “\(summary)”", text: text)
    }
}

// MARK: - The picker

/// Choose a destination, and say what should happen on the way.
///
/// One panel rather than two steps. The instruction field is the whole point of
/// the feature, and putting it behind a second popover would make the common
/// case — send this, minus the PII — the one that costs the most clicks.
struct RelayForm: View {
    @EnvironmentObject private var workspace: Workspace
    let source: Session
    /// Built lazily, and allowed to fail: reading a 400KB file to compose a
    /// popover that may never open is wasted work, and a file that can't be
    /// relayed should say so here rather than halfway through.
    let payload: () -> Result<Relay.Payload, Error>
    @Binding var isPresented: Bool
    /// Prefilled when the form was opened by a `/send` that couldn't resolve
    /// its destination — the instruction you typed shouldn't have to be typed
    /// again just because the name didn't match.
    var initialInstruction: String = ""

    @State private var destination: Session.ID?
    @State private var instruction = ""

    /// The payload, built once for the life of the panel.
    ///
    /// `payload()` reads the material off disk — up to four hundred kilobytes
    /// for a file relay — and it was being called straight from `body`, so
    /// every keystroke in the instruction field below re-read the file to
    /// redraw a text field. Held in a reference type rather than `@State`
    /// because it has to be filled during the first body evaluation, before an
    /// `onAppear` could run, or the panel opens on a blank frame.
    private final class Resolved { var value: Result<Relay.Payload, Error>? }
    @State private var cache = Resolved()

    private var resolved: Result<Relay.Payload, Error> {
        if let value = cache.value { return value }
        let value = payload()
        cache.value = value
        return value
    }

    /// Everything you could send to: real sessions, this one excluded. Grouped
    /// by account in the sidebar's own order, so the list reads the same way
    /// the sidebar does.
    private var targets: [Session] {
        Account.allCases.flatMap { account in
            workspace.sessions(in: account).filter { !$0.isEphemeral && $0.id != source.id }
        }
    }

    private var chosen: Session? { targets.first { $0.id == destination } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch resolved {
            case .failure(let error):
                refusal(error)
            case .success(let ready):
                PopoverHeader("Send", top: 0)
                summary(ready)
                Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                list
                Divider().overlay(Theme.rule)
                instructionField
                footer(ready)
            }
        }
        // The same measure as `HandoffForm`. They share a popover and a switch
        // between them, and two widths would make the panel jump on every flip.
        .padding(.top, Theme.s3)
        .frame(width: 280)
        .onAppear {
            instruction = initialInstruction
            if destination == nil { destination = targets.first?.id }
        }
    }

    /// What's about to travel, named. Without this the panel is a list of
    /// conversations and a Send button, and nothing at all about the material.
    private func summary(_ ready: Relay.Payload) -> some View {
        Text(ready.label)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, Theme.s5)
    }

    private func refusal(_ error: Error) -> some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text("Can't send this")
                .font(.system(size: 13, weight: .medium))
            Text((error as? Relay.Refusal)?.message ?? error.localizedDescription)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
    }

    @ViewBuilder
    private var list: some View {
        if targets.isEmpty {
            Text("There's nowhere to send this — it's the only session open.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.s5)
                .padding(.bottom, Theme.s4)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(targets) { session in
                        PopoverRow(title: session.name,
                                   blurb: blurb(for: session),
                                   selected: destination == session.id) {
                            destination = session.id
                        }
                    }
                }
            }
            // Nine sessions is a normal roster and fits; a very long one
            // scrolls rather than growing the popover past the window.
            .frame(maxHeight: 240)
        }
    }

    /// The account, and — where it applies — the fact that this crosses one.
    /// Personal and Enterprise are the same model behind different credentials,
    /// and the credentials are the entire point here.
    private func blurb(for session: Session) -> String {
        session.account == source.account
            ? session.account.shortTitle
            : "\(session.account.shortTitle) — different account"
    }

    private var instructionField: some View {
        TextField("Optional — e.g. remove company PII",
                  text: $instruction, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1...4)
            .padding(.horizontal, Theme.s5)
            .padding(.vertical, Theme.s4)
    }

    /// The button says where it's going, every time.
    ///
    /// A first-run confirmation dialog was the alternative and is worse: a
    /// dialog you can dismiss forever is a dialog that stops being read after
    /// the second time. A button that reads "Send to Claude Personal" can't be
    /// dismissed and can't go stale.
    private func footer(_ ready: Relay.Payload) -> some View {
        HStack {
            Text(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "Sent as-is" : "\(source.account.shortTitle) transforms it first")
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
            Spacer(minLength: Theme.s4)
            Button(chosen.map { "Send to \($0.account.shortTitle)" } ?? "Send") {
                guard let chosen else { return }
                isPresented = false
                Relay.send(ready, from: source, to: chosen,
                           instruction: instruction, in: workspace)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen == nil)
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
    }

}
