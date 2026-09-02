import SwiftUI
import AppKit

/// The git facts the window's chrome says out loud, read once and shared.
///
/// Three surfaces now name the branch — the title bar's breadcrumb, the status
/// strip along the foot of the window, and the inspector's Workspace section —
/// and each redraws on a different trigger. Asked independently that is three
/// `rev-parse` subprocesses per session per window activation, for one short
/// string that changes when you switch branches and at no other time.
///
/// `LocationChip` owned this logic privately and was right to, while it was the
/// only asker. It isn't any more, and three private copies of a subprocess call
/// is the shape of a stutter nobody can find later.
///
/// Nothing here is on the network and nothing here writes: `rev-parse` and
/// `remote get-url` are both local reads, which is why they can be answered on
/// a utility queue and cached without a staleness policy more elaborate than
/// "ask again when the app comes forward".
@MainActor
final class RepoStatus: ObservableObject {
    static let shared = RepoStatus()

    struct Reading: Equatable {
        /// Nil outside a work tree, or with Git switched off.
        var branch: String?
        /// `owner/repo` where the remote is one we can name that way, the host
        /// otherwise, nil with no remote at all.
        var slug: String?
    }

    @Published private(set) var readings: [URL: Reading] = [:]

    /// Directories with a read already in flight.
    ///
    /// Three views appearing in the same frame each call `follow` for the same
    /// directory, and without this that is three sets of subprocesses racing to
    /// publish the same answer.
    private var inFlight: Set<URL> = []

    func reading(for directory: URL) -> Reading { readings[directory] ?? Reading() }

    /// Ask, unless the answer is already here. Cheap enough to call from
    /// `onAppear`.
    func follow(_ directory: URL) {
        guard readings[directory] == nil else { return }
        refresh(directory)
    }

    /// Ask again regardless. Called when the app comes forward, which is when a
    /// branch switched in a terminal becomes something the window is wrong about.
    func refresh(_ directory: URL) {
        // With Git switched off the breadcrumb is the folder's name and nothing
        // else, so don't spend two subprocesses working out something that will
        // not be drawn.
        guard Features.isOn(.git) else {
            readings[directory] = Reading()
            return
        }
        guard !inFlight.contains(directory) else { return }
        inFlight.insert(directory)

        Task { [weak self] in
            let reading = await Task.detached(priority: .utility) { () -> Reading in
                guard let root = Git.root(of: directory) else { return Reading() }
                let branch = Git.currentBranch(in: root)
                let slug = Git.remote(in: root).map { Forge.detect(remote: $0).displayName }
                return Reading(branch: branch.isEmpty ? nil : branch, slug: slug)
            }.value

            guard let self else { return }
            self.inFlight.remove(directory)
            // Only on a change. `readings` is `@Published`, and republishing an
            // identical dictionary redraws the title bar, the status strip and
            // the inspector on every window activation for nothing.
            if self.readings[directory] != reading { self.readings[directory] = reading }
        }
    }
}

/// Keeps `RepoStatus` current for one directory, for as long as the view is up.
///
/// A modifier rather than a call in `onAppear`, because the other half — asking
/// again when the app comes forward — is the half that gets forgotten, and
/// three surfaces each remembering it separately is three chances to forget.
struct FollowsRepo: ViewModifier {
    let directory: URL

    func body(content: Content) -> some View {
        content
            .task(id: directory) { RepoStatus.shared.follow(directory) }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                RepoStatus.shared.refresh(directory)
            }
    }
}

extension View {
    func followsRepo(_ directory: URL) -> some View {
        modifier(FollowsRepo(directory: directory))
    }
}
