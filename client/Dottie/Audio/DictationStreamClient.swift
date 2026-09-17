import Foundation

/// Streams PTT dictation audio to the gateway's `/v1/dictation/stream` proxy
/// while the key is held, so key-release only pays the finalize tail instead of
/// a full-utterance batch decode (dictation-amazing-plan P2).
///
/// One instance = one recording. Every failure is soft: `finish` reports
/// failure and the caller falls back to the untouched WAV batch path, so
/// streaming can only make dictation faster, never break it. All state is
/// confined to a serial queue; audio-thread callers only enqueue.
final class DictationStreamClient {
    /// ~320ms @ 16kHz int16 mono — matches realtime.js STREAM_FEED_MIN_BYTES.
    private static let chunkBytes = 10_240

    private let queue = DispatchQueue(label: "com.example.dottie.dictation-stream")
    private var sessionID: String?
    private var starting = true
    private var failed = false
    private var pending = Data()
    private var sending = false
    private var finishRequested: ((Bool) -> Void)?
    /// Cumulative transcript snapshot from the last audio POST.
    private(set) var lastPartial = ""
    /// Called on the main thread with the cumulative transcript after each audio
    /// POST — drives the live-transcript overlay during the PTT hold.
    var onPartial: ((String) -> Void)?

    private var baseURL: String { "http://127.0.0.1:\(AppPorts.agentServer)/v1/dictation/stream" }

    // MARK: - Lifecycle

    /// Opens the stream session. Failures just mark the client failed — the
    /// recording continues on the WAV path regardless.
    func begin() {
        guard let url = URL(string: baseURL) else { queue.async { self.failed = true }; return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.0
        ClientManager.setAgentAuth(on: &request)
        ClientManager.shared.urlSession.dataTask(with: request) { data, response, error in
            self.queue.async {
                self.starting = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil, status == 200, let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = json["id"] as? String, !id.isEmpty {
                    self.sessionID = id
                    AppLogger.shared.debug("[DictationStream] session open: \(id)")
                    self.maybeSend()
                } else {
                    // 503 = stream model not provisioned (batch-only parakeet) — expected, quiet.
                    self.failed = true
                    AppLogger.shared.debug("[DictationStream] session open failed (status \(status)) — batch fallback")
                }
                self.resolveFinishIfIdle()
            }
        }.resume()
    }

    /// Appends converted 16 kHz mono int16 PCM. Safe from the audio thread.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async {
            guard !self.failed else { return }
            self.pending.append(pcm)
            self.maybeSend()
        }
    }

    /// Flushes remaining audio, finalizes the session, and returns the full
    /// transcript. `completion(nil)` means the caller must run the batch path.
    func finish(completion: @escaping (_ result: (text: String, sttMs: Int?, formatMs: Int?)?) -> Void) {
        queue.async {
            AppLogger.shared.debug("[DictationStream] finish requested (starting=\(self.starting) sending=\(self.sending) pending=\(self.pending.count)B session=\(self.sessionID ?? "nil") failed=\(self.failed))")
            if self.failed || (self.sessionID == nil && !self.starting) {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // Wait for the start round-trip and the last audio POST to settle,
            // then flush the tail chunk and finalize.
            self.finishRequested = { ok in
                guard ok, let id = self.sessionID else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.postFinalize(id: id, completion: completion)
            }
            // maybeSend, not resolveFinishIfIdle: a tail chunk smaller than
            // chunkBytes only flushes once finishRequested is set, and if no POST
            // is in flight nothing else will ever call maybeSend again — going
            // straight to resolveFinishIfIdle deadlocked finish() whenever the
            // last chunk landed before key release (the field no-paste hang).
            // maybeSend flushes the tail and falls through to resolveFinishIfIdle
            // itself when there is nothing to send.
            self.maybeSend()
        }
    }

    /// Frees the session (ESC cancel). Fire-and-forget.
    func cancel() {
        queue.async {
            self.failed = true
            guard let id = self.sessionID, let url = URL(string: "\(self.baseURL)/\(id)") else { return }
            self.sessionID = nil
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 2.0
            ClientManager.setAgentAuth(on: &request)
            ClientManager.shared.urlSession.dataTask(with: request).resume()
        }
    }

    // MARK: - Internals (all on `queue`)

    /// Sends the next chunk when one is due and nothing is in flight. Ordered:
    /// exactly one POST at a time so PCM arrives in sequence.
    private func maybeSend() {
        guard !failed, !sending, let id = sessionID else { return }
        let flushing = finishRequested != nil
        guard pending.count >= Self.chunkBytes || (flushing && !pending.isEmpty) else {
            resolveFinishIfIdle()
            return
        }
        let chunk = pending
        pending = Data()
        sending = true

        guard let url = URL(string: "\(baseURL)/\(id)/audio") else { failed = true; return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6.0
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        ClientManager.setAgentAuth(on: &request)
        request.httpBody = chunk
        ClientManager.shared.urlSession.dataTask(with: request) { data, response, error in
            self.queue.async {
                self.sending = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error != nil || status != 200 {
                    self.failed = true
                    AppLogger.shared.debug("[DictationStream] audio feed failed (status \(status)) — batch fallback")
                } else if let data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let text = json["text"] as? String {
                    if text != self.lastPartial, let onPartial = self.onPartial {
                        DispatchQueue.main.async { onPartial(text) }
                    }
                    self.lastPartial = text
                }
                self.maybeSend()
                self.resolveFinishIfIdle()
            }
        }.resume()
    }

    /// Fires the pending finish continuation once no start/send is in flight
    /// and the pending buffer is drained (or the client failed).
    private func resolveFinishIfIdle() {
        guard let handler = finishRequested else { return }
        if failed {
            finishRequested = nil
            handler(false)
            return
        }
        guard !starting, !sending, pending.isEmpty else {
            AppLogger.shared.debug("[DictationStream] finish waiting (starting=\(starting) sending=\(sending) pending=\(pending.count)B)")
            return
        }
        finishRequested = nil
        handler(true)
    }

    private func postFinalize(id: String, completion: @escaping ((text: String, sttMs: Int?, formatMs: Int?)?) -> Void) {
        AppLogger.shared.debug("[DictationStream] finalizing session \(id)")
        sessionID = nil
        guard let url = URL(string: "\(baseURL)/\(id)/finalize") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClientManager.setAgentAuth(on: &request)

        // Same polish options the batch upload sends — the gateway runs the same
        // formatTranscript pass on the finalized text when enabled.
        let opts = GatewayClient.dictationFormatOptions()
        var body: [String: Any] = ["dictationFormat": opts.enabled]
        if opts.enabled {
            if !opts.vocabulary.isEmpty { body["vocabulary"] = opts.vocabulary }
            if !opts.appContext.isEmpty { body["appContext"] = opts.appContext }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        ClientManager.shared.urlSession.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                AppLogger.shared.debug("[DictationStream] finalize failed (status \(status)) — batch fallback")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let timings = json["timings"] as? [String: Any]
            DispatchQueue.main.async {
                completion((text, timings?["stt_ms"] as? Int, timings?["format_ms"] as? Int))
            }
        }.resume()
    }
}
