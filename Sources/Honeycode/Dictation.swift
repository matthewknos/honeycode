import AVFoundation
import Speech
import SwiftUI

/// Push-to-talk transcription for the composer.
///
/// Prefers on-device recognition where the locale supports it, so captures
/// never leave the machine. Falls back to the network recogniser only if the
/// device model isn't available.
@MainActor
final class Dictation: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    /// Smoothed 0…1 microphone level, for the waveform.
    @Published private(set) var level: Double = 0
    @Published private(set) var errorMessage: String?

    /// Fires on every revision with what the whole field should now read —
    /// anything typed before the mic was pressed, plus the text so far.
    var onTranscript: ((String) -> Void)?

    /// Whatever was already written when recording began.
    ///
    /// Each revision replaces the *dictated span*, not the field: the recogniser
    /// re-reports its whole transcript every time it changes its mind about an
    /// earlier word, so the callback has to overwrite. Without a record of what
    /// came before, that overwrote the half-message you were finishing by voice.
    private var prefix = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
        ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// `continuing` is the text already in the field, which dictation appends
    /// to rather than replaces.
    func toggle(continuing existing: String = "") {
        isRecording ? stop() : start(continuing: existing)
    }

    // MARK: Start / stop

    /// Set between the button press and the engine actually running.
    ///
    /// Permission is asynchronous, so without this a second press before the
    /// callback returns would reach `beginCapture` twice and call `installTap`
    /// on a bus that already has one — which raises, not returns an error.
    private var isStarting = false

    /// The one that's recording, if any.
    ///
    /// There is one microphone, and with columns there are now several
    /// composers that can ask for it. Two `AVAudioEngine` taps on the same
    /// input is not a race worth having — the second either fails or captures
    /// the same audio into the wrong draft. Starting one stops the other, which
    /// is also what you'd expect from pressing a second mic button.
    private static weak var active: Dictation?

    func start(continuing existing: String = "") {
        guard !isRecording, !isStarting else { return }
        if let active = Self.active, active !== self { active.stop() }
        Self.active = self
        errorMessage = nil
        isStarting = true
        // A space between the two, unless there's already one — speech arrives
        // without leading whitespace and "…and thenthe next bit" is the result.
        prefix = existing.isEmpty || existing.hasSuffix(" ") || existing.hasSuffix("\n")
            ? existing : existing + " "

        requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.isStarting = false
                self.errorMessage =
                    "Microphone or speech access denied. Enable Honeycode under "
                    + "System Settings › Privacy & Security."
                return
            }
            self.beginCapture()
            self.isStarting = false
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil

        withAnimation(Motion.disclose) { level = 0 }
    }

    private func beginCapture() {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable right now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            errorMessage = "No audio input device."
            return
        }

        // Defensive: a tap left behind by an aborted run would make this raise.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let self else { return }
            let rms = Self.rms(of: buffer)
            Task { @MainActor in self.updateLevel(rms) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            return
        }

        transcript = ""
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onTranscript?(self.prefix + self.transcript)
                }
                // A recogniser error usually means the on-device model isn't
                // installed. Surface it rather than just going quiet — the
                // symptom is otherwise identical to "the mic didn't hear you".
                if let error, self.transcript.isEmpty {
                    self.errorMessage =
                        "Dictation failed: \(error.localizedDescription). "
                        + "Check Dictation is enabled in System Settings › Keyboard."
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stop()
                }
            }
        }
    }

    // MARK: Helpers

    private func updateLevel(_ rms: Float) {
        // Map to a usable range and smooth, so the waveform breathes instead of
        // flickering frame to frame.
        let normalised = min(1, max(0, Double(rms) * 14))
        level = level * 0.72 + normalised * 0.28
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        return (sum / Float(count)).squareRoot()
    }

    private func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async { completion(micGranted) }
            }
        }
    }
}

