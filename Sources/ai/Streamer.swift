import Foundation
import Combine

/// Prints one session's reply as it arrives.
///
/// The transcript is an array that the adapter mutates in place, so "what is
/// new" isn't handed to us — it has to be worked out. This keeps a high-water
/// mark per item and writes only the tail, which is what makes a streamed reply
/// appear a word at a time instead of being reprinted from the top on every
/// delta.
final class Streamer {

    private let session: Session
    private let account: Account
    private var feed: AnyCancellable?
    /// Characters already written, per transcript item.
    private var printed: [UUID: Int] = [:]
    /// Tool rows already announced, so a running tool doesn't reprint per tick.
    private var announced: Set<UUID> = []
    /// Tools already reported as failed, so a failure prints once.
    private var failed: Set<UUID> = []
    private var openedSpeaker = false
    /// Whether tool activity is shown. Off for delegates, whose work would
    /// interleave into an unreadable braid when several run at once.
    private let verbose: Bool

    init(_ session: Session, as account: Account, verbose: Bool = true) {
        self.session = session
        self.account = account
        self.verbose = verbose

        // Everything already in the transcript counts as printed.
        //
        // Without this, attaching to a session that has spoken before replays
        // the whole conversation: the lead's assembly turn reprinted its own
        // planning prose *and* the raw `ai-delegate` block that had been
        // carefully stripped the first time. A streamer shows what happens
        // next, not what already did.
        for item in session.items {
            switch item {
            case .assistant(let id, let text): printed[id] = text.count
            case .tool(let id, _, _, _, _, _),
                 .diff(let id, _, _, _, _),
                 .search(let id, _, _, _, _),
                 .notice(let id, _):
                announced.insert(id)
            default: continue
            }
        }
        // Same throttle and the same reasoning as `Session.askOpinion`'s mirror:
        // this fires twice per streamed token and the work it does is a scan of
        // the whole transcript.
        feed = session.objectWillChange
            .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.render() }
    }

    func stop() { feed = nil }

    /// Flush whatever arrived after the last tick. Called once more when the
    /// turn lands, because the final delta and `isRunning = false` can share a
    /// tick that the throttle then swallows.
    func finish() {
        render()
        feed = nil
    }

    private func render() {
        for item in session.items {
            switch item {
            case .assistant(let id, let text):
                emit(id: id, text: text)
            case .thinking, .user, .todos, .compaction, .opinion:
                continue
            case .tool(let id, _, let name, let target, _, let state):
                note(id: id, "\(name) \(target)", state)
            case .diff(let id, _, let file, let rows, let state):
                note(id: id, "edit \(file) (\(rows.count) lines)", state)
            case .search(let id, _, let query, _, let state):
                note(id: id, "search \(query)", state)
            case .notice(let id, let text):
                guard announced.insert(id).inserted, verbose else { continue }
                Console.status(text)
            }
        }
    }

    private func emit(id: UUID, text: String) {
        let already = printed[id] ?? 0
        guard text.count > already else { return }
        if !openedSpeaker {
            Console.speaker(account)
            openedSpeaker = true
        }
        let tail = String(text.dropFirst(already))
        printed[id] = text.count
        Console.write(tail)
    }

    /// One line per tool, the first time it's seen. The state it *ends* in is
    /// what matters, but waiting for that would leave a long build silent — so
    /// it prints on sight and only failures are worth a second line.
    private func note(id: UUID, _ label: String, _ state: ToolState) {
        guard verbose else { return }
        if announced.insert(id).inserted {
            Console.status(label)
        }
        if case .failed(let message) = state, failed.insert(id).inserted {
            Console.failure(message.isEmpty ? "\(label) failed" : message)
        }
    }
}
