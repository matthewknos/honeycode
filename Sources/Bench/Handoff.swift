import SwiftUI

/// Send a reply or a proposed edit to a different agent.
///
/// This is the one thing Honeycode can do that a single-vendor GUI structurally
/// cannot: an answer from Claude reviewed by GPT-5.6, or a diff Claude wants to
/// apply checked by Gemini before it lands. Two vendors, three accounts, one
/// window — the transcripts are already in one format, so the whole feature is
/// composing a prompt and switching selection.
enum Handoff {

    /// A reply, with the question that prompted it.
    ///
    /// The question matters more than it looks: an answer reviewed without the
    /// thing it was answering invites the reviewer to critique the wrong target.
    static func review(reply: String, question: String?, from session: Session) -> String {
        var prompt = """
        A different coding agent — \(session.account.title), \(session.model.title) — \
        produced the answer below. Review it: is it correct, is anything missing, \
        and what would you do differently? Be specific and brief. Don't act on it.
        """
        if let question, !question.isEmpty {
            prompt += "\n\n--- The question ---\n\(question)"
        }
        prompt += "\n\n--- Its answer ---\n\(reply)"
        return prompt
    }

    /// A proposed edit, rendered back into a unified diff the other agent can read.
    static func review(diff rows: [DiffRow], file: String, from session: Session) -> String {
        """
        A different coding agent — \(session.account.title), \(session.model.title) — \
        wants to make the change below to `\(file)`. Review it for correctness and \
        risk before it's applied. Don't edit anything yourself.

        ```diff
        \(unified(rows))
        ```
        """
    }

    /// Rebuild the patch text. The rows carry line numbers on both sides, so
    /// this reads as a real diff rather than as two pasted files.
    private static func unified(_ rows: [DiffRow]) -> String {
        rows.map { row in
            switch row.kind {
            case .add:     return "+" + row.text
            case .del:     return "-" + row.text
            case .context: return " " + row.text
            }
        }
        .joined(separator: "\n")
    }
}

/// The hover affordance, and the little form behind it.
///
/// Opens a *fresh, throwaway* session rather than sending into an existing one.
/// A review dropped into a live conversation drags its own history in as
/// context and leaves the answer buried in a thread about something else — and
/// the whole point of asking a second agent is that it hasn't already agreed
/// with the first.
struct HandoffMenu: View {
    @EnvironmentObject private var workspace: Workspace
    let source: Session
    /// Built lazily — composing a prompt for a form that may never open is
    /// wasted work on every hover.
    let prompt: () -> String

    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                // A chip behind it: this sits beside prose, and a bare glyph
                // against a sentence reads as a smudge rather than a control.
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Ask another agent about this")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            HandoffForm(source: source, prompt: prompt, isPresented: $showing)
                .environmentObject(workspace)
        }
    }
}

private struct HandoffForm: View {
    @EnvironmentObject private var workspace: Workspace
    let source: Session
    let prompt: () -> String
    @Binding var isPresented: Bool

    @State private var account: Account
    @State private var model: AgentModel?
    @State private var effort: EffortChoice = .high

    init(source: Session, prompt: @escaping () -> String, isPresented: Binding<Bool>) {
        self.source = source
        self.prompt = prompt
        self._isPresented = isPresented
        // Default to the *other vendor*. Asking Claude to check Claude is a
        // second opinion in name only, and cross-vendor review is the one thing
        // this app can do that a single-vendor GUI can't.
        self._account = State(initialValue: source.account == .copilot ? .personal : .copilot)
    }

    private var models: [AgentModel] { ModelCatalog.models(for: account) }
    private var showsEffort: Bool { account != .copilot }

    var body: some View {
        // One scroll region for the whole form, at a fixed height.
        //
        // The model list used to be its own `ScrollView` with only a
        // *maximum* height — so when the account rows and five effort rows
        // claimed the space first, it collapsed to about one line and showed a
        // model's description with the name clipped off above it. A flexible
        // scroll view inside a self-sizing stack has no floor to stand on.
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    body_
                }
            }
            .frame(height: 320)

            Divider().overlay(Theme.rule)
            footer
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private var body_: some View {
        Group {
            header("Ask")
            ForEach(Account.allCases) { option in
                PopoverRow(title: option.title,
                           blurb: option == source.account ? "Same agent that answered" : nil,
                           selected: account == option) {
                    account = option
                    model = ModelCatalog.models(for: option).first
                }
            }

            Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
            header("Model")
            ForEach(models) { choice in
                PopoverRow(title: choice.title, blurb: choice.blurb,
                           selected: (model ?? models.first)?.id == choice.id) {
                    model = choice
                }
            }

            if showsEffort {
                Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                header("Effort")
                // Inline rows, not a nested menu: this is already a popover,
                // and a popover opening a menu is a stack of surfaces for one
                // choice out of five.
                ForEach(EffortChoice.allCases) { choice in
                    PopoverRow(title: choice.title, selected: effort == choice) {
                        effort = choice
                    }
                }
            }

        }
    }

    /// Pinned below the scroll region, so Ask is always reachable however long
    /// the model list runs.
    private var footer: some View {
        HStack {
            Text("Answers here, in this thread")
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
            Spacer()
            Button("Ask") { ask() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.s5)
            .padding(.bottom, Theme.s3)
    }

    private func ask() {
        isPresented = false
        let chosen = model ?? models.first
        // Runs out of sight and reports back into this transcript. The session
        // it uses is never added to the roster — you asked a question, you
        // didn't start a conversation.
        source.askOpinion(account: account,
                          modelID: chosen?.id,
                          effort: effort,
                          modelTitle: chosen?.title ?? "",
                          prompt: prompt())
    }
}
