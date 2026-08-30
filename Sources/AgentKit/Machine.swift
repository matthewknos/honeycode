import Foundation

/// What this build is going to run on.
///
/// One question, asked at compile time rather than measured, which is the
/// right way round: an architecture is chosen before anything runs, and the
/// thing being compiled for *is* the thing that will run it.
///
/// There was a second — whether the graphics were fast enough for an animated
/// background — and it went with the background it existed to decide about.
enum Machine {

    /// The architecture this was built for, for anything that wants to say so.
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
