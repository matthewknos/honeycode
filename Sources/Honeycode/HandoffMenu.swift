import SwiftUI

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
    /// Owned by the row rather than by this view.
    ///
    /// It has to be: the button is only built while the pointer is on the row,
    /// so the moment you set off towards the popover the row un-hovers, this
    /// view is destroyed, and any state living here goes with it — taking the
    /// popover down before you can reach it. The row keeps itself alive by
    /// watching this instead.
    @Binding var showing: Bool
    /// Built lazily — composing a prompt for a form that may never open is
    /// wasted work on every hover.
    let prompt: () -> String
    /// The same row, as material to hand to a session you already have.
    ///
    /// Nil for rows there's nothing sensible to relay from. When it's present
    /// the popover grows a switch, rather than the gutter growing a second
    /// chip: two glyphs a row apart, both meaning "do something with this
    /// elsewhere", is a choice you'd have to make before knowing what either
    /// one leads to.
    var payload: (() -> Result<Relay.Payload, Error>)?

    /// Which half of the popover is showing. Ask first because it's the older
    /// gesture and the cheaper one — it costs a throwaway turn and changes
    /// nothing; a relay puts material into a conversation and leaves it there.
    @State private var mode = Mode.ask

    private enum Mode: String, CaseIterable, Identifiable {
        case ask, send
        var id: String { rawValue }
        var title: String { self == .ask ? "Ask" : "Send" }
    }

    var body: some View {
        Button { showing.toggle() } label: {
            // A chip behind it: this sits beside prose, and a bare glyph
            // against a sentence reads as a smudge rather than a control.
            IconChip(symbol: "arrow.turn.up.right", weight: .semibold, diameter: 22)
        }
        .buttonStyle(.plain)
        .help(payload == nil
              ? "Ask another agent about this"
              : "Ask another agent about this, or send it to one of your sessions")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            VStack(spacing: 0) {
                if let payload {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, Theme.s5)
                    .padding(.top, Theme.s4)

                    if mode == .send {
                        RelayForm(source: source, payload: payload, isPresented: $showing)
                    } else {
                        HandoffForm(source: source, prompt: prompt, isPresented: $showing)
                    }
                } else {
                    HandoffForm(source: source, prompt: prompt, isPresented: $showing)
                }
            }
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
    /// Which account's model panel is open.
    @State private var modelsFor: Account?
    /// Where the pointer is, turned into `modelsFor` after a pause.
    @State private var hover = HoverPolicy<Account>()
    @State private var side: HorizontalEdge = .trailing

    init(source: Session, prompt: @escaping () -> String, isPresented: Binding<Bool>) {
        self.source = source
        self.prompt = prompt
        self._isPresented = isPresented
        // Default to a *different agent*. Asking Claude to check Claude is a
        // second opinion in name only, and cross-vendor review is the one thing
        // this app can do that a single-vendor GUI can't.
        //
        // Picked by walking the accounts rather than naming one, so a new agent
        // becomes a candidate by existing. Claude Personal and Claude Enterprise
        // count as the same agent here — different credentials, same model
        // behind them.
        let others = Account.allCases.filter { $0.agentName != source.account.agentName }
        self._account = State(initialValue: others.first ?? .copilot)
    }

    private var models: [AgentModel] { ModelCatalog.models(for: account) }

    /// Four account rows and a footer, with the models a hover away.
    ///
    /// This used to be one 320pt scroll region holding accounts, then every
    /// model, then five effort levels — the whole decision tree flattened into a
    /// column you scrolled through to find the part you wanted. It needed the
    /// scroll region because Copilot alone contributes twenty models.
    ///
    /// The same shape as the composer's model picker now: the list you're
    /// choosing from is short, and what belongs to each row arrives beside it
    /// when you rest there. Four rows fit without scrolling at all.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Ask")
            ForEach(Account.allCases) { option in
                accountRow(option)
            }

            Divider().overlay(Theme.rule)
            footer
        }
        .padding(.top, Theme.s3)
        .frame(width: 280)
        .background {
            PopoutSide(needed: Self.panelWidth + Theme.s7) { side = $0 }
        }
        .popoutSettles(hover, into: $modelsFor)
    }

    private func accountRow(_ option: Account) -> some View {
        PopoverRow(title: option.title,
                   blurb: option == source.account
                       ? "Same agent that answered" : option.agentName,
                   selected: account == option,
                   disclosure: side) {
            // Clicking takes the account and its default model. Picking a
            // specific model is what the panel is for.
            choose(option, model: ModelCatalog.models(for: option).first)
        }
        .popout(option, hover: $hover, open: $modelsFor, side: side) {
            panel(for: option)
        }
    }

    /// That account's models, and its effort levels where it has any.
    ///
    /// Effort sits in the same panel rather than behind a third level. It's five
    /// rows, and a popover opening a popover opening a popover for one choice
    /// out of five is a corridor, not a menu.
    private func panel(for option: Account) -> some View {
        let choices = ModelCatalog.models(for: option)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(option.title)
                    ForEach(choices) { choice in
                        PopoverRow(title: choice.title, blurb: choice.blurb,
                                   selected: account == option
                                       && (model ?? choices.first)?.id == choice.id) {
                            choose(option, model: choice)
                        }
                    }

                    if option.hasEffort {
                        Divider().overlay(Theme.rule).padding(.vertical, Theme.s2)
                        header("Effort")
                        ForEach(EffortChoice.allCases) { choice in
                            PopoverRow(title: choice.title,
                                       selected: account == option && effort == choice) {
                                effort = choice
                                choose(option, model: model ?? choices.first)
                            }
                        }
                    }
                }
            }
            // Copilot alone offers twenty models across five vendors, so this
            // one does still need a ceiling.
            .frame(maxHeight: 320)
        }
        .padding(.vertical, Theme.s3)
        .frame(width: Self.panelWidth)
    }

    /// Take a choice and put the panel away, without closing the form — the
    /// question hasn't been asked yet, and Ask is still a button away.
    private func choose(_ option: Account, model chosen: AgentModel?) {
        account = option
        // Only keep a model this account can actually run.
        //
        // The effort rows pass `model ?? choices.first`, and `model` survives
        // an account switch — so picking a model under Copilot and then
        // clicking an effort row in the Claude panel locked a Copilot model ID
        // onto a Claude account, and `ask` launched the reviewer with it.
        // Falling back to the account's first model is the same default the
        // panel already shows as selected.
        let available = ModelCatalog.models(for: option)
        model = available.contains { $0.id == chosen?.id } ? chosen : available.first
        modelsFor = nil
        hover = HoverPolicy()
    }

    private static let panelWidth: CGFloat = 250

    /// Says what you've settled on as well as offering the button, because the
    /// model now lives behind a hover and would otherwise be invisible at the
    /// moment you commit to it.
    private var footer: some View {
        HStack {
            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
            Spacer()
            Button("Ask") { ask() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.s5)
        .padding(.vertical, Theme.s4)
    }

    /// Who is about to be asked, and with what.
    ///
    /// The account and model are both a hover away now, so without this the
    /// footer would offer a button and no statement of what pressing it does.
    private var summary: String {
        var text = account.shortTitle
        if let name = (model ?? models.first)?.title { text += " · " + name }
        if account.hasEffort { text += " · " + effort.title.lowercased() }
        return text
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
