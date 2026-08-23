import Foundation

/// What this build is going to run on.
///
/// One question so far, and it is asked at compile time rather than measured.
/// That is the right way round here: a deployment target and an architecture
/// are chosen before anything runs, and the thing being compiled for *is* the
/// thing that will run it. Asking Metal at launch would be a framework import
/// and a device query to learn something the build already decided.
enum Machine {

    /// Whether a surface that redraws continuously can be treated as free.
    ///
    /// On Apple silicon it can: the GPU shares memory with everything else by
    /// design, and compositing a canvas behind a window is not a thing you can
    /// feel. On the Intel Macs this still builds for it is the opposite — a
    /// 2020 13-inch runs Iris Plus integrated graphics on the same memory bus
    /// as the rest of the machine, and the flux background is a `WKWebView`
    /// drawing a couple of hundred scaled strips a frame across the full
    /// window. It is comfortably the most expensive thing in the app there.
    ///
    /// A default, not a rule. `Feature.motion` is the switch, this only says
    /// which way it starts.
    static var hasFastGraphics: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

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
