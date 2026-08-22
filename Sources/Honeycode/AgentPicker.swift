import SwiftUI
import AppKit

/// Everything else this app can drive, in a list you can add from.
///
/// The accounts step used to end with a sentence: "Add a CLI of your own later
/// in Settings ▸ Accounts." Which was true, and was also the app admitting that
/// the answer to "what else works with this" lived in a form with six fields,
/// four of which you had to go and look up. Anybody who did not already know
/// the exact command for the Gemini CLI left with four accounts and no idea
/// there were thirty more.
///
/// So the list is the answer. It is `AgentCatalogue`, which is generated from
/// the Agent Client Protocol's own registry, and adding one is a click: the
/// command, its arguments and any environment come with the entry, and the
/// handle and colour are chosen so that nothing has to be decided to get
/// started. Everything is still editable afterwards, and **Something else…**
/// still opens the form for an agent nobody has published.
struct AgentPicker: View {
    let existing: [CustomAccount]
    let done: (Outcome) -> Void

    enum Outcome {
        /// Save this and close.
        case add(CustomAccount)
        /// Not in the list — open the form instead.
        case freeform
        case cancel
    }

    @State private var query = ""
    @FocusState private var searching: Bool

    /// The catalogue's own order, which is not alphabetical — the names most
    /// people are looking for come first. See `tools/acp-catalogue.py`, which
    /// is where that judgement is made and argued for.
    private var matches: [CatalogueAgent] { AgentCatalogue.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.rule)
            list
            Divider().overlay(Theme.rule)
            footer
        }
        .frame(width: 580, height: 560)
        .background(Theme.canvas)
        // Straight into the field. Thirty-five rows is more than a glance, and
        // the person opening this usually arrived with a name in mind.
        .onAppear { searching = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text("Add an agent")
                .font(Theme.display(16))
            Text("The Agent Client Protocol's own registry — "
                 + "\(AgentCatalogue.all.count) agents, each with the command it "
                 + "needs already filled in.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.s3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("", text: $query, prompt: Text("Search"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searching)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.s4)
            .frame(height: 26)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.cornerField))
        }
        .padding(.horizontal, Theme.s6)
        .padding(.top, Theme.s6)
        .padding(.bottom, Theme.s5)
    }

    @ViewBuilder
    private var list: some View {
        if matches.isEmpty {
            VStack(spacing: Theme.s4) {
                Text("Nothing here answers to “\(query)”.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Button("Add it by hand") { done(.freeform) }
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { agent in
                        row(agent)
                        if agent.id != matches.last?.id {
                            Divider().overlay(Theme.rule)
                        }
                    }
                }
                .padding(.horizontal, Theme.s6)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ agent: CatalogueAgent) -> some View {
        let already = AgentCatalogue.added(agent, in: existing)
        return HStack(alignment: .top, spacing: Theme.s5) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                HStack(spacing: Theme.s3) {
                    Text(agent.name)
                        .font(.system(size: 13))
                    Text("@\(agent.handle)")
                        .font(Theme.monoSmall)
                        .foregroundStyle(.tertiary)
                    // Said on the row, because it is the one thing that
                    // changes what happens after you press Add: an `npx` agent
                    // works immediately and this one waits on a download you
                    // have to go and start yourself.
                    if !agent.isFetched {
                        Text("installs itself")
                            .font(Theme.label)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.s3)
                            .padding(.vertical, 1)
                            .background(Theme.well, in: Capsule())
                    }
                }
                Text(agent.blurb)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.s4)

            if already {
                Text("added")
                    .font(Theme.label)
                    .foregroundStyle(.tertiary)
                    .padding(.top, Theme.s1)
            } else {
                Button("Add") {
                    done(.add(AgentCatalogue.draft(agent, existing: existing)))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, Theme.s4)
    }

    private var footer: some View {
        HStack(spacing: Theme.s4) {
            Button("Something else…") { done(.freeform) }
                .buttonStyle(.link)
                .help("The form, for an agent that isn't in the registry — an "
                      + "in-house one, or a second seat on a different key.")
            Spacer()
            Button("Done") { done(.cancel) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.s5)
    }
}
