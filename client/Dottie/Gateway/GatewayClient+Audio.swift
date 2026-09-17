import Foundation
import AVFoundation

extension GatewayClient {
    // MARK: - Speech-to-Text

    /// Result of a transcription: the text plus optional server-side stage timings
    /// (ms) used for the dictation-latency instrumentation. No transcript text is
    /// carried in the timing fields.
    struct DictationResult {
        let text: String
        let sttMs: Int?
        let formatMs: Int?
    }

    /// Transcribes an audio file via the audio server's OpenAI-compatible STT endpoint.
    func transcribeAudio(from fileURL: URL, model: String? = nil, completion: @escaping (Result<DictationResult, Error>) -> Void) {
        AppLogger.shared.debug("[STT] transcribeAudio called for: \(fileURL.lastPathComponent)")

        // Warm-path fast lane: STT readiness is already tracked in-memory (updated
        // by the status poller), so skip the per-dictation /health round-trip when
        // we know it's up. Only cold starts pay the probe — and that now polls at
        // 250ms instead of 2s steps.
        if isSTTReady {
            performTranscription(from: fileURL, model: model, completion: completion)
            return
        }
        waitForAudioServer(attempt: 1, maxAttempts: 8, delay: 0.25) { [weak self] ready in
            guard let self = self else { return }
            if ready {
                self.performTranscription(from: fileURL, model: model, completion: completion)
            } else {
                // The probe target is the gateway /health (:1317), not parakeet
                // directly — all STT (local AND cloud) flows through the gateway,
                // so this 503 means dictation is offline regardless of provider.
                // "Dictation service" wording avoids implying an xAI-mode user is
                // missing a local audio server they never run.
                AppLogger.shared.warn("[STT] Gateway not responding after 3 attempts")
                DispatchQueue.main.async {
                    completion(.failure(ClientError.serverError(503, "Dictation service not available")))
                }
            }
        }
    }

    private func waitForAudioServer(attempt: Int, maxAttempts: Int, delay: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let healthURL = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/health") else {
            completion(false)
            return
        }

        var healthRequest = URLRequest(url: healthURL)
        healthRequest.timeoutInterval = 3.0

        ClientManager.shared.urlSession.dataTask(with: healthRequest) { _, response, error in
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                completion(true)
            } else if attempt < maxAttempts {
                AppLogger.shared.info("[STT] Audio server not ready, retrying (\(attempt)/\(maxAttempts))")
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else {
                        completion(false)
                        return
                    }
                    self.waitForAudioServer(attempt: attempt + 1, maxAttempts: maxAttempts, delay: delay, completion: completion)
                }
            } else {
                completion(false)
            }
        }.resume()
    }

    private func performTranscription(from fileURL: URL, model: String?, retryCount: Int = 0, completion: @escaping (Result<DictationResult, Error>) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/audio/transcriptions") else {
            completion(.failure(ClientError.invalidURL))
            return
        }

        let sttModel = model ?? UserDefaults.standard.string(forKey: "selectedSTTModel") ?? ModelDefaults.sttModel

        do {
            let resources = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = resources.fileSize, fileSize > 100 * 1024 * 1024 {
                AppLogger.shared.error("[STT] File size exceeds 100MB limit")
                completion(.failure(ClientError.fileTooLarge))
                return
            }
        } catch {
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60.0
        ClientManager.setAgentAuth(on: &request)

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        do {
            let audioData = try Data(contentsOf: fileURL)
            let filename = fileURL.lastPathComponent
            let mimeType = sttMimeType(for: fileURL.pathExtension)

            guard let fileHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8),
                  let newlineData = "\r\n".data(using: .utf8) else {
                completion(.failure(ClientError.invalidResponse))
                return
            }

            body.append(fileHeader)
            body.append(audioData)
            body.append(newlineData)
            appendFormField("model", value: sttModel, to: &body, boundary: boundary)

            // Optional local dictation post-processor (Settings → Dictation). When
            // enabled, the gateway runs a local LLM cleanup pass on the transcript
            // using `vocabulary` (known names/terms) to fix spelling/punctuation.
            let opts = Self.dictationFormatOptions()
            // Header mirror of the dictationFormat flag: "0" lets the gateway
            // skip decoding the whole multipart WAV just to learn there are no
            // polish fields inside (the common default-off case).
            request.setValue(opts.enabled ? "1" : "0", forHTTPHeaderField: "X-Dictation-Format")
            if opts.enabled {
                appendFormField("dictationFormat", value: "true", to: &body, boundary: boundary)
                if !opts.vocabulary.isEmpty {
                    appendFormField("vocabulary", value: opts.vocabulary, to: &body, boundary: boundary)
                }
                if !opts.appContext.isEmpty {
                    appendFormField("appContext", value: opts.appContext, to: &body, boundary: boundary)
                }
            }

            guard let endBoundaryData = "--\(boundary)--\r\n".data(using: .utf8) else {
                completion(.failure(ClientError.invalidResponse))
                return
            }
            body.append(endBoundaryData)
        } catch {
            completion(.failure(error))
            return
        }

        request.httpBody = body

        ClientManager.shared.urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    AppLogger.shared.error("[STT] Network error: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status >= 500 && status < 600 && retryCount < 2 {
                        let delay = Double(retryCount + 1) * 2.0
                        AppLogger.shared.warn("[STT] Server error \(status), retrying in \(delay)s (attempt \(retryCount + 1)/2)")
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.performTranscription(from: fileURL, model: model, retryCount: retryCount + 1, completion: completion)
                        }
                        return
                    }
                    completion(.failure(ClientError.serverError(status, "Audio Server")))
                    return
                }

                if let data = data {
                    do {
                        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                        if let transcriptionText = json?["text"] as? String {
                            let timings = json?["timings"] as? [String: Any]
                            let sttMs = timings?["stt_ms"] as? Int
                            let formatMs = timings?["format_ms"] as? Int
                            completion(.success(DictationResult(text: transcriptionText, sttMs: sttMs, formatMs: formatMs)))
                        } else {
                            completion(.failure(ClientError.noTranscriptionText))
                        }
                    } catch {
                        completion(.failure(error))
                    }
                } else {
                    completion(.failure(ClientError.emptyResponse))
                }
            }
        }.resume()
    }

    /// Preloads the default STT model by sending a minimal silent audio file.
    func preloadSTTModel(completion: ((Bool) -> Void)? = nil) {
        let sttModel = ModelDefaults.sttModel

        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/audio/transcriptions") else {
            completion?(false)
            return
        }

        let silentWav = createSilentWav(duration: 0.1)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120.0
        ClientManager.setAgentAuth(on: &request)

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"silent.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(silentWav)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append(sttModel.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        ClientManager.shared.urlSession.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if error != nil {
                    completion?(false)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion?(status == 200)
            }
        }.resume()
    }

    private func createSilentWav(duration: Double) -> Data {
        let sampleRate: Int = 16000
        let bitsPerSample: Int = 16
        let numChannels: Int = 1
        let numSamples = Int(Double(sampleRate) * duration)
        let dataSize = numSamples * numChannels * (bitsPerSample / 8)
        let fileSize = 36 + dataSize

        var wavData = Data()
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(numChannels).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        let byteRate = sampleRate * numChannels * (bitsPerSample / 8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        let blockAlign = numChannels * (bitsPerSample / 8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        wavData.append(Data(count: dataSize))

        return wavData
    }

    /// Calculates RMS (root mean square) audio level from a PCM buffer.
    static func calculateRMSLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        return sqrt(sum / Float(frameLength))
    }

    /// Appends a simple text multipart form field to `body`.
    private func appendFormField(_ name: String, value: String, to body: inout Data, boundary: String) {
        guard let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8) else { return }
        body.append(part)
    }

    /// Resolves dictation post-processor settings + vocabulary for the upload:
    /// custom words + contact names (zero-setup) + foreground-app context.
    static func dictationFormatOptions() -> (enabled: Bool, vocabulary: String, appContext: String) {
        DictationVocabulary.options()
    }

    private func sttMimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "m4a": return "audio/m4a"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "audio/wav"
        }
    }

    // MARK: - STT Readiness

    /// True when dictation / realtime voice input can run.
    /// STT is routed through the gateway, so a running agent is the gate.
    var isSTTReady: Bool {
        AgentManager.shared.status == .running
    }

    /// Polls `/system/status` until STT is ready or `timeoutSec` elapses.
    /// Completion is called on the main queue.
    func waitForSTTReady(timeoutSec: Double = 30, pollIntervalSec: Double = 0.5, completion: @escaping (Bool) -> Void) {
        if isSTTReady {
            DispatchQueue.main.async { completion(true) }
            return
        }

        Task {
            let deadline = Date().addingTimeInterval(timeoutSec)
            while Date() < deadline {
                await pollStatus()
                if await MainActor.run(body: { isSTTReady }) {
                    await MainActor.run { completion(true) }
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalSec * 1_000_000_000))
            }
            await MainActor.run { completion(false) }
        }
    }

    /// Surfaces the persistent `stt_unavailable` banner and polls until the gateway recovers.
    func surfaceSTTUnavailableBanner(message: String = "Dictation service unavailable — voice input offline.") {
        NotificationCenter.default.post(
            name: .showErrorBanner,
            object: ChatBannerError(
                code: "stt_unavailable",
                message: message,
                actionLabel: nil,
                action: nil
            )
        )
        startSTTRecoveryPoll()
    }

    /// Polls gateway `/health` every 5s until it returns 200, then clears the banner.
    func startSTTRecoveryPoll() {
        guard sttRecoveryPollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] t in
            self?.checkAgentHealth { healthy in
                guard healthy else { return }
                t.invalidate()
                self?.sttRecoveryPollTimer = nil
                NotificationCenter.default.post(
                    name: .clearErrorBanner,
                    object: nil,
                    userInfo: ["code": "stt_unavailable"]
                )
                AppLogger.shared.info("[STT] Gateway back online — cleared stt_unavailable banner")
            }
        }
        sttRecoveryPollTimer = timer
        timer.fire()
    }
}
