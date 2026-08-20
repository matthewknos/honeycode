import Foundation
import Combine

/// Prints one session's reply as it arrives.
///
/// The work of deciding *what is new* lives in `Scrollback`, which Honeycode's
/// coding mode shares — this is the half that turns styled runs into ANSI. The
/// two used to be one file each, which is how the app and the CLI ended up
/// describing the same tool call two different ways.
final class Streamer {

    private let session: Session
    private let seat: Seat
    private let scrollback: Scrollback
    private var feed: AnyCancellable?

    init(_ session: Session, as seat: Seat, verbose: Bool = true) {
        self.session = session
        self.seat = seat

        // Tool activity is off for delegates, whose work would interleave into
        // an unreadable braid when several run at once.
        var options = ScrollbackOptions.cli(speaker: seat.handle)
        options.showsActivity = verbose
        self.scrollback = Scrollback(options)

        // Everything already in the transcript counts as printed. A streamer
        // shows what happens next, not what already did.
        scrollback.catchUp(items: session.items, todos: session.todos)

        // Same throttle and the same reasoning as `Session.askOpinion`'s
        // mirror: this fires twice per streamed token.
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
        Console.emit(scrollback.drain(items: session.items, todos: session.todos),
                     accent: Console.tint(seat.account))
    }
}
