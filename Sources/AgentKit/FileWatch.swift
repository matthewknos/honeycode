import Foundation

/// Watches one file and says when it changed.
///
/// Polled rather than event-driven, which is the unfashionable choice and the
/// correct one here. Every serious editor — and every agent's write tool —
/// saves by writing a temporary file and renaming it over the target, so the
/// file you opened a descriptor on is not the file that exists a moment later.
/// A `DispatchSource` watching that descriptor reports one `.rename` and then
/// goes silent forever, which is exactly the failure mode you don't want in a
/// live preview: it works when you test it once and stops working during real
/// editing.
///
/// A `stat` twice a second costs nothing measurable and cannot be fooled by a
/// replacement, a truncation, a delete-and-recreate, or an editor that does all
/// three.
@MainActor
final class FileWatch: ObservableObject {
    private var timer: Timer?
    private var url: URL?
    private var stamp: Stamp?
    private var onChange: (() -> Void)?

    /// Size as well as date, because a file written twice inside the same
    /// second — which agent edits routinely are — has the same modification
    /// date both times on some filesystems.
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?

        init(_ url: URL) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                           .fileSizeKey])
            modified = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    /// Start watching, or stop if handed nil.
    ///
    /// Re-watching the same file is a no-op rather than a restart, so this can
    /// be called from `onChange(of:)` and `onAppear` alike without the stamp
    /// being reset out from under an edit in flight.
    func watch(_ url: URL?, onChange: @escaping () -> Void) {
        guard url != self.url else { return }
        stop()
        self.url = url
        self.onChange = onChange
        guard let url else { return }
        stamp = Stamp(url)
        // Repeating on the common run loop mode, so it keeps ticking while a
        // menu is open or the divider is being dragged.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        url = nil
        stamp = nil
    }

    private func tick() {
        guard let url else { return }
        let now = Stamp(url)
        // A vanished file reports nil for both, and firing on that would blank
        // the panel in the split second an atomic save leaves the path empty.
        guard now.modified != nil || now.size != nil else { return }
        guard now != stamp else { return }
        stamp = now
        onChange?()
    }

    deinit { timer?.invalidate() }
}
