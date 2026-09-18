import AVFoundation
import Observation
import os
import Speech

/// The in-app recorder: the mic button's equivalent of the Siri intent.
///
/// **Audio never leaves the phone, and is never written down** (FR15 §5.2).
/// Microphone buffers go from the audio engine, through a format converter,
/// straight into the analyzer, in memory, and are dropped. There is no file,
/// no recording, and nothing to upload — only the text that comes out.
///
/// Built on `SpeechAnalyzer` (iOS 26), which runs **only on the device**:
/// there is no server path to fall back to, so the promise on screen —
/// "transcribed on your phone" — holds by construction rather than by a flag.
/// `SpeechTranscriber` is used where the phone supports it, `DictationTranscriber`
/// otherwise; both are on-device.
///
/// The language model is an Apple asset that may need downloading the first
/// time. That is a download *to* the phone — nothing of the seller's goes up —
/// but it needs signal, so a phone that has never recorded and is standing in
/// a car park is told to try once with signal, or to use Siri.
@MainActor
@Observable
final class SpeechCapture {
    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case finishing
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    /// 0…1, for the level meter.
    private(set) var level: Float = 0
    private(set) var transcript = ""
    private(set) var startedAt: Date?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    // Finalized text so far, and the volatile tail still being revised.
    private var finalized = ""
    private var volatile = ""

    // MARK: Starting

    func start() async {
        guard phase == .idle else { return }
        phase = .preparing

        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .unavailable("Sales needs the microphone to take a note. You can allow it in Settings.")
            return
        }

        guard let module = await Self.transcriber(for: Locale.current) else {
            phase = .unavailable(Self.cannotTranscribe)
            return
        }

        do {
            try await Self.ensureModelInstalled(for: module.module)
        } catch {
            phase = .unavailable("The first time, your phone needs signal to download its speech model from Apple. Nothing of yours is sent. Try again with signal, or use Siri.")
            return
        }

        do {
            try await beginSession(with: module)
            startedAt = Date()
            phase = .listening
        } catch CaptureError.modelUnavailable {
            stopAudio()
            phase = .unavailable(Self.cannotTranscribe)
        } catch CaptureError.noMicrophone {
            stopAudio()
            phase = .unavailable("This phone’s microphone isn’t available right now. Please try again.")
        } catch {
            Logger(subsystem: "ca.2labs.sales", category: "SpeechCapture")
                .error("Recording could not start: \(String(describing: error), privacy: .public)")
            stopAudio()
            phase = .unavailable("The microphone couldn’t start. Please try again.")
        }
    }

    private func beginSession(with module: Transcriber) async throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audio.setActive(true, options: .notifyOthersOnDeactivation)

        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        // A phone with no working input reports an empty format; there is
        // nothing to convert, so say so rather than fail further in.
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw CaptureError.noMicrophone }
        // No format means the model is not actually usable on this device —
        // the simulator, for one, reports a model it cannot run.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.module])
        else { throw CaptureError.modelUnavailable }
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat)
        else { throw CaptureError.noAudioFormat }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation

        let analyzer = SpeechAnalyzer(modules: [module.module])
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await update in module.updates() {
                    self?.receive(update)
                }
            } catch {
                // The session ended or failed; whatever was heard is kept.
            }
        }
        try await analyzer.start(inputSequence: stream)

        engine.inputNode.installTap(
            onBus: 0, bufferSize: 4096, format: micFormat,
            block: Self.tap(converting: converter, to: analyzerFormat, into: continuation, meter: self))
        engine.prepare()
        try engine.start()
    }

    // MARK: Stopping

    /// Stop listening and return what was said, after the analyzer's final pass.
    func stop() async -> String {
        guard phase == .listening else { return transcript }
        phase = .finishing
        stopAudio()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        // Anything still volatile at the end is the best reading there is.
        let text = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        transcript = text
        return text
    }

    /// Throw it away: nothing is saved.
    func cancel() {
        stopAudio()
        input?.finish()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        transcript = ""
        reset()
    }

    private func receive(_ update: Transcriber.Update) {
        if update.isFinal {
            finalized += update.text
            volatile = ""
        } else {
            volatile = update.text
        }
        transcript = finalized + volatile
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        level = 0
    }

    private func reset() {
        analyzer = nil
        input = nil
        resultsTask = nil
        finalized = ""
        volatile = ""
        startedAt = nil
        phase = .idle
    }

    private static let cannotTranscribe =
        "This phone can’t transcribe your language on its own, and Sales won’t send your voice anywhere to do it. Siri can still take a note."

    enum CaptureError: Error { case noMicrophone, modelUnavailable, noAudioFormat }

    // MARK: Choosing and preparing the model

    /// `SpeechTranscriber` where the phone supports it; `DictationTranscriber`,
    /// the older on-device model, where it does not.
    private static func transcriber(for locale: Locale) async -> Transcriber? {
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speech(SpeechTranscriber(
                locale: supported, transcriptionOptions: [],
                reportingOptions: [.volatileResults], attributeOptions: []))
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(DictationTranscriber(locale: supported, preset: .progressiveLongDictation))
        }
        return nil
    }

    private static func ensureModelInstalled(for module: any SpeechModule) async throws {
        if await AssetInventory.status(forModules: [module]) == .installed { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: Callbacks from other threads
    //
    // Built outside the main actor on purpose. A closure written inside this
    // @MainActor class is isolated to the main thread, and Swift traps when
    // the audio engine calls it from its own thread.

    /// The tap runs on the audio thread. Each buffer is converted to the
    /// analyzer's format, handed over, and measured for the meter; it is never
    /// stored.
    nonisolated private static func tap(
        converting converter: AVAudioConverter,
        to format: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation,
        meter owner: SpeechCapture
    ) -> AVAudioNodeTapBlock {
        return { [weak owner] buffer, _ in
            let level = normalizedLevel(of: buffer)
            Task { @MainActor in owner?.level = level }

            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    nonisolated private static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // Roughly -50 dB to 0 dB onto 0…1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 50) / 50))
    }
}

/// The two on-device transcribers behind one face: what the recorder needs
/// from either is the module to hand the analyzer, and a stream of text with
/// a flag saying whether it is final.
enum Transcriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    struct Update: Sendable {
        let text: String
        let isFinal: Bool
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let module): module
        case .dictation(let module): module
        }
    }

    func updates() -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch self {
                    case .speech(let module):
                        for try await result in module.results {
                            continuation.yield(Update(text: String(result.text.characters), isFinal: result.isFinal))
                        }
                    case .dictation(let module):
                        for try await result in module.results {
                            continuation.yield(Update(text: String(result.text.characters), isFinal: result.isFinal))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
