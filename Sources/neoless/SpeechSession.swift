import AVFoundation
import Foundation
import NeolessCore
import Speech

/// Apple's on-device speech recognition (the same engine as macOS Dictation),
/// fed live while the user speaks, so the transcript is ready the moment they stop.
/// `requiresOnDeviceRecognition` keeps audio on this Mac.
///
/// If the recognition task stops while the user is still talking (a final result,
/// a "no speech" timeout after a long pause, an error), a fresh task takes over the
/// rest of the audio and `diedEarly` is set, so the caller can run a second pass. The
/// number of takeovers grows with the audio (`RecognitionTiming.restartBudget`); if it
/// runs out anyway, `lostAudio` says the rest was never recognized.
final class SpeechSession: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self { case .unsupported(let why): return why }
        }
    }

    /// Main thread, every time the running transcript changes.
    var onPartial: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer
    private let queue: OperationQueue
    private let hints: [String]

    // Guarded by `inputLock`: touched from the audio thread.
    private let inputLock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest
    private var inputEnded = false
    private var framesAppended: Double = 0
    private var sampleRate: Double = AudioRecorder.sampleRate

    // Only touched on `queue`.
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var restarts = 0
    /// False for a second pass: all of its audio is queued on one request, a new task would get none.
    private var allowsRestarts = true
    private var results = 0   // results received, to tell whether more arrived after a final
    private var finalBeforeStop = false   // the current task's latest result was a final while the user was talking
    private var accumulator = TranscriptAccumulator()
    private var finished = false
    private var audioEnded = false
    private var waiter: CheckedContinuation<String, Never>?

    // Written on `queue`, read from the main thread: guarded by `stateLock`, so reading
    // never waits for the recognizer queue.
    private let stateLock = NSLock()
    private var _lastError: Error?
    private var _diedEarly = false
    private var _lostAudio = false

    var lastError: Error? { stateLock.withLock { _lastError } }
    /// The live transcript may be missing audio: the recognizer stopped while the user
    /// was still talking, or did not finalize in time. Worth a second pass.
    var diedEarly: Bool { stateLock.withLock { _diedEarly } }
    /// The session gave up while audio was still coming (no takeovers left): everything after
    /// that was never recognized live.
    var lostAudio: Bool { stateLock.withLock { _lostAudio } }

    private func setError(_ error: Error) { stateLock.withLock { _lastError = error } }
    private func markDiedEarly() { stateLock.withLock { _diedEarly = true } }
    private func markLostAudio() { stateLock.withLock { _diedEarly = true; _lostAudio = true } }

    init(localeID: String, hints: [String]) throws {
        guard let shared = Self.shared(localeID: localeID) else {
            throw Failure.unsupported("macOS 不支持这种识别语言")
        }
        guard shared.recognizer.supportsOnDeviceRecognition else {
            throw Failure.unsupported("需要下载离线识别模型：系统设置 › 键盘 › 听写")
        }
        recognizer = shared.recognizer
        queue = shared.queue
        self.hints = hints
        request = Self.makeRequest(hints: hints, partials: true)
    }

    /// Like `init`, but first gives the recognizer up to `timeout` seconds to load
    /// its on-device model (right after login it can briefly report unavailable)
    /// and to become available, instead of failing at once. Used by DictationController.begin
    /// for every live session.
    static func prepare(localeID: String, hints: [String], timeout: TimeInterval = 3) async throws -> SpeechSession {
        _ = await waitUntilReady(localeID: localeID, timeout: timeout)
        return try SpeechSession(localeID: localeID, hints: hints)
    }

    private static func makeRequest(hints: [String], partials: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = partials
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = hints
        return request
    }

    // MARK: Recognizer cache

    private struct Shared {
        let recognizer: SFSpeechRecognizer
        let queue: OperationQueue
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Shared] = [:]

    /// One recognizer per locale for the life of the app, delivering on one serial queue.
    /// Reusing it skips the model load on every dictation.
    private static func shared(localeID: String) -> Shared? {
        cacheLock.withLock {
            if let hit = cache[localeID] { return hit }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else { return nil }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            recognizer.queue = queue
            recognizer.defaultTaskHint = .dictation
            let entry = Shared(recognizer: recognizer, queue: queue)
            cache[localeID] = entry
            return entry
        }
    }

    /// Creates the recognizer for `localeID` ahead of time so the first dictation does not
    /// pay for it. Called at launch (DictationController.init) and when the language changes
    /// (AppSettings.localeID didSet). Cheap and idempotent.
    static func warmUp(localeID: String) {
        _ = shared(localeID: localeID)
    }

    /// Whether this Mac can recognize `localeID` on-device right now (language
    /// downloaded under 系统设置 › 键盘 › 听写). Read by ServiceMonitor for the menu-bar
    /// warning; the setup checklist row comes with the UI step.
    static func onDeviceAvailable(localeID: String) -> Bool {
        shared(localeID: localeID)?.recognizer.supportsOnDeviceRecognition ?? false
    }

    /// Polls every 100 ms until the recognizer supports on-device recognition and is
    /// available, up to `timeout`. Returns whether it became ready.
    static func waitUntilReady(localeID: String, timeout: TimeInterval = 3) async -> Bool {
        guard let shared = shared(localeID: localeID) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let r = shared.recognizer
            if r.supportsOnDeviceRecognition && r.isAvailable { return true }
            if Date() >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Live session

    /// Starts recognizing. If the recognizer is momentarily unavailable the task starts
    /// as soon as it is (up to 3 s); audio appended meanwhile is queued on the request.
    func start() {
        queue.addOperation { self.startTask(waited: 0) }
    }

    private func startTask(waited: Int) {
        guard !finished, task == nil else { return }
        if !recognizer.isAvailable && waited < 30 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.queue.addOperation { self?.startTask(waited: waited + 1) }
            }
            return
        }
        generation += 1
        finalBeforeStop = false
        let current = generation
        let request = inputLock.withLock { self.request }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, generation: current)
        }
    }

    /// Safe to call from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        inputLock.withLock {
            guard !inputEnded else { return }
            request.append(buffer)
            framesAppended += Double(buffer.frameLength)
            sampleRate = buffer.format.sampleRate
        }
    }

    /// Seconds of audio appended so far.
    var audioSeconds: TimeInterval {
        inputLock.withLock { sampleRate > 0 ? framesAppended / sampleRate : 0 }
    }

    /// Ends the audio and waits (bounded) for the final transcript. The wait is never
    /// shorter than `timeout` and grows a little for long recordings (at most 12 s).
    /// If it runs out first, the text so far is returned and `diedEarly` is set.
    func finish(timeout: TimeInterval) async -> String {
        await finish(limit: RecognitionTiming.liveFinish(requested: timeout, audioSeconds: audioSeconds))
    }

    private func finish(limit: TimeInterval) async -> String {
        queue.addOperation { self.audioEnded = true }
        inputLock.withLock {
            inputEnded = true
            request.endAudio()
        }
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            queue.addOperation {
                if self.finished {
                    continuation.resume(returning: self.accumulator.text)
                    return
                }
                self.waiter = continuation
                guard let task = self.task, task.state == .completed || task.state == .canceling else { return }
                if self.finalBeforeStop {
                    // The task ended on its own with a final just before the stop: nothing more
                    // will come, and the audio after that final was never recognized.
                    self.markDiedEarly()
                    self.complete()
                } else {
                    // endAudio() can complete the task before its final result reaches `queue`.
                    // Wait for that result instead of returning text without the final revision.
                    self.completeWhenQuiet(self.generation, results: self.results)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [weak self] in
                self?.queue.addOperation {
                    guard let self, !self.finished else { return }
                    self.markDiedEarly()   // did not finalize in time: the tail may be missing
                    self.complete()
                }
            }
        }
        queue.addOperation {
            self.task?.cancel()
            self.task = nil
        }
        return text
    }

    /// Stops recognition at once; a pending `finish` returns the text so far.
    func cancel() {
        inputLock.withLock {
            inputEnded = true
            request.endAudio()
        }
        queue.addOperation {
            self.complete()
            self.task?.cancel()
            self.task = nil
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, generation: Int) {
        // Ignore a replaced task, and anything after completion (such as the
        // "canceled" error our own cancel() produces).
        guard generation == self.generation, !finished else { return }
        if let result {
            // A final before the user stopped is the end of an utterance too.
            let endsUtterance = result.speechRecognitionMetadata != nil || (result.isFinal && !audioEnded)
            accumulator.update(result.bestTranscription.formattedString, endsUtterance: endsUtterance,
                               isFinal: result.isFinal)
            results += 1
            finalBeforeStop = result.isFinal && !audioEnded
            let text = accumulator.text
            DispatchQueue.main.async { [weak self] in self?.onPartial?(text) }
            if result.isFinal {
                // Some macOS versions send a final for every utterance and keep going;
                // others stop the task. Before the stop: keep listening unless the task
                // really ended. After it: finish once nothing more arrives for 250 ms.
                if audioEnded, task?.state == .completed {
                    complete()
                } else {
                    checkAfterFinal(generation, results: results, delay: audioEnded ? 0.25 : 0.3)
                }
            }
        }
        if let error {
            let e = error as NSError
            if audioEnded {
                if !SpeechErrorText.isCancellation(domain: e.domain, code: e.code) { setError(error) }
                complete()
                return
            }
            // The task died while the user was still talking.
            let noSpeech = SpeechErrorText.isNoSpeech(domain: e.domain, code: e.code)
            let cancelled = SpeechErrorText.isCancellation(domain: e.domain, code: e.code)
            if !noSpeech && !cancelled { setError(error) }
            if !noSpeech || !accumulator.text.isEmpty { markDiedEarly() }
            takeOver()
        }
    }

    private func checkAfterFinal(_ generation: Int, results seen: Int, delay: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.queue.addOperation {
                guard let self, generation == self.generation, !self.finished else { return }
                let ended = self.task.map { $0.state == .completed || $0.state == .canceling } ?? true
                if self.audioEnded {
                    if ended || self.results == seen { self.complete() }
                } else if ended {
                    self.markDiedEarly()
                    self.takeOver()
                }
            }
        }
    }

    /// How long `finish` waits for the final result of a task that already completed.
    private static let pendingFinalGrace: TimeInterval = 0.5

    /// Completes once no result has arrived for `pendingFinalGrace`; every result that
    /// does arrive restarts the wait. The overall `finish` limit still applies.
    private func completeWhenQuiet(_ generation: Int, results seen: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pendingFinalGrace) { [weak self] in
            self?.queue.addOperation {
                guard let self, generation == self.generation, !self.finished else { return }
                if self.results == seen {
                    self.complete()
                } else {
                    self.completeWhenQuiet(generation, results: self.results)
                }
            }
        }
    }

    /// Starts a fresh task on a fresh request for the rest of the audio. Without
    /// restarts left, the session completes with what it has.
    private func takeOver() {
        task = nil
        accumulator.startNewTask()
        guard allowsRestarts, restarts < RecognitionTiming.restartBudget(audioSeconds: audioSeconds) else {
            if allowsRestarts, !inputLock.withLock({ inputEnded }) { markLostAudio() }
            complete()
            return
        }
        restarts += 1
        let fresh = Self.makeRequest(hints: hints, partials: true)
        let ended = inputLock.withLock { () -> Bool in
            if inputEnded { return true }
            request = fresh
            return false
        }
        guard !ended else {
            complete()
            return
        }
        startTask(waited: 0)
    }

    /// "No speech detected" is not a failure worth reporting.
    static func isNoSpeech(_ error: Error) -> Bool {
        let e = error as NSError
        return SpeechErrorText.isNoSpeech(domain: e.domain, code: e.code)
    }

    /// Chinese, user-facing; nil for no-speech and cancellation. Safe on the main thread.
    var errorDescription: String? {
        guard let error = lastError else { return nil }
        let e = error as NSError
        return SpeechErrorText.message(domain: e.domain, code: e.code, description: e.localizedDescription)
    }

    private func complete() {
        finished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: accumulator.text)
        }
    }

    // MARK: Second pass

    /// Second chance: recognize the whole recording again from memory. Used when the live
    /// session ended empty, lost audio, or restarted although there was speech. The recording
    /// is cut into pieces of at most 30 s at quiet moments (`SecondPass.pieces`), each with its
    /// own task: a task fed all of its audio at once cannot hand the rest to a new one if it
    /// stops at the end of an utterance. Bounded by `timeout` for all pieces together
    /// (`RecognitionTiming.secondPass` if nil) and cancellable: cancelling the calling Task
    /// stops recognition at once and returns "". `complete`: every piece was recognized to its
    /// end in time.
    static func recognize(samples: [Float], localeID: String, hints: [String],
                          timeout: TimeInterval? = nil) async -> (text: String, complete: Bool) {
        let rate = AudioRecorder.sampleRate
        let budget = timeout ?? RecognitionTiming.secondPass(audioSeconds: Double(samples.count) / rate)
        let deadline = Date().addingTimeInterval(budget)
        var parts: [String] = []
        var complete = true
        for piece in SecondPass.pieces(samples, sampleRate: rate) {
            let left = deadline.timeIntervalSinceNow
            guard left > 0.5 else {
                complete = false
                break
            }
            let limit = min(left, RecognitionTiming.secondPass(audioSeconds: Double(piece.count) / rate))
            guard let result = await recognizePiece(Array(samples[piece]), localeID: localeID, hints: hints, limit: limit)
            else { return ("", false) }
            parts.append(result.text)
            if !result.complete { complete = false }
        }
        return Task.isCancelled ? ("", false) : (TextJoin.join(parts), complete)
    }

    /// One piece of the second pass; nil when cancelled or the recognizer is unavailable.
    private static func recognizePiece(_ samples: [Float], localeID: String, hints: [String],
                                       limit: TimeInterval) async -> (text: String, complete: Bool)? {
        guard !Task.isCancelled,
              let session = try? SpeechSession(localeID: localeID, hints: hints),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)
        else { return nil }
        // Partial results stay on: the recognizer may reset at pauses, and the
        // accumulator needs the partials to stitch the segments together.
        session.allowsRestarts = false
        let text = await withTaskCancellationHandler {
            session.start()
            let chunk = Int(AudioRecorder.sampleRate)
            var offset = 0
            while offset < samples.count, !Task.isCancelled {
                let count = min(chunk, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { src in
                    buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: count)
                }
                session.append(buffer)
                offset += count
            }
            return await session.finish(limit: limit)
        } onCancel: {
            session.cancel()
        }
        // A piece that stopped early or ran out of time (`diedEarly`) may miss its end.
        return Task.isCancelled ? nil : (text, !session.diedEarly)
    }
}
