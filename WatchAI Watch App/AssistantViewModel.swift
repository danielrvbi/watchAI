import AVFAudio
import Combine
import Foundation

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var answer: String?
#if os(watchOS)
    @Published private(set) var liveTranscript = ""
    @Published private(set) var voiceError: String?
    @Published private(set) var isRecording = false
    @Published private(set) var voiceInputActive = false
#endif

    private let answerRequest: @MainActor (String) async throws -> String
    private let speechOutput: SpeechOutput
    private var activeRequest: Task<Void, Never>?
    private var latestRequestID = UUID()
#if os(watchOS)
    private var voiceTask: Task<Void, Never>?
    private var voiceRequestID = UUID()
    private var microphone: MicrophoneCapture?
    private var voxtral: VoxtralRealtimeService?
#endif

    init(
        answerRequest: (@MainActor (String) async throws -> String)? = nil,
        speechOutput: SpeechOutput? = nil
    ) {
        self.speechOutput = speechOutput ?? AppleSpeechOutput()
        self.answerRequest = answerRequest ?? { request in
            guard let mistralKey = Self.key(named: "MistralAPIKey"),
                  let tavilyKey = Self.key(named: "TavilyAPIKey") else {
                throw AssistantError.missingConfiguration
            }
            let service = MistralService(
                apiKey: mistralKey,
                tavily: TavilyService(apiKey: tavilyKey)
            )
            return try await service.answer(to: request)
        }
    }

    func submit(_ request: String) {
        speechOutput.stop()
        activeRequest?.cancel()
#if os(watchOS)
        let priorVoiceTask = voiceTask
#endif
        let requestID = UUID()
        latestRequestID = requestID
        answer = nil

        activeRequest = Task {
            do {
#if os(watchOS)
                if let priorVoiceTask { await priorVoiceTask.value }
#endif
                try Task.checkCancellation()
                let response = try await answerRequest(request)
                guard !Task.isCancelled, latestRequestID == requestID else { return }
                present(response)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, latestRequestID == requestID else { return }
                let response = error is AssistantError
                    ? "The app is missing its API configuration."
                    : "I couldn't get an answer right now. Please try again."
                present(response)
            }
        }
    }

    func cancelCurrentRequest() {
        activeRequest?.cancel()
        activeRequest = nil
        latestRequestID = UUID()
        speechOutput.stop()
        answer = nil
#if os(watchOS)
        cancelVoiceInput()
#endif
    }

#if os(watchOS)
    func toggleVoiceInput() {
        if isRecording {
            stopVoiceInput()
        } else {
            startVoiceInput()
        }
    }

    func cancelVoiceInput() {
        voiceRequestID = UUID()
        voiceTask?.cancel()
        microphone?.stop()
        voxtral?.cancel()
        microphone = nil
        voxtral = nil
        isRecording = false
        voiceInputActive = false
        liveTranscript = ""
        voiceError = nil
    }

    private func startVoiceInput() {
        let previous = voiceTask
        cancelVoiceInput()
        speechOutput.stop()
        activeRequest?.cancel()
        latestRequestID = UUID()
        answer = nil

        let requestID = UUID()
        voiceRequestID = requestID
        isRecording = true
        voiceInputActive = true

        voiceTask = Task {
            // Wait for the prior recording to release its audio session first.
            if let previous { await previous.value }
            guard !Task.isCancelled, voiceRequestID == requestID else { return }

            let microphone = MicrophoneCapture()
            self.microphone = microphone
            var service: VoxtralRealtimeService?

            do {
                guard let apiKey = Self.key(named: "MistralAPIKey") else {
                    throw AssistantError.missingConfiguration
                }
                try await microphone.prepare()
                try Task.checkCancellation()
                guard isRecording, voiceRequestID == requestID else { throw CancellationError() }

                let realtime = VoxtralRealtimeService(apiKey: apiKey)
                service = realtime
                voxtral = realtime
                try await realtime.connect(
                    onDelta: { delta in
                        guard self.voiceRequestID == requestID else { return }
                        self.liveTranscript += delta
                    },
                    onFailure: {
                        guard self.voiceRequestID == requestID else { return }
                        self.isRecording = false
                        self.microphone?.stop()
                    }
                )
                try Task.checkCancellation()
                guard isRecording, voiceRequestID == requestID else { throw CancellationError() }

                let chunks = try microphone.start()
                guard isRecording else { throw VoxtralRealtimeService.Failure.transcription }
                try await realtime.stream(chunks)
                try Task.checkCancellation()
                guard voiceRequestID == requestID else { throw CancellationError() }

                let transcript = try await realtime.finish()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                realtime.cancel()
                await microphone.release()
                guard !Task.isCancelled, voiceRequestID == requestID else { return }
                clearVoiceSession()
                if transcript.isEmpty {
                    liveTranscript = ""
                    voiceError = "I didn't hear anything. Try again."
                } else {
                    liveTranscript = transcript
                    submit(transcript)
                }
            } catch {
                service?.cancel()
                await microphone.release()
                guard !Task.isCancelled, voiceRequestID == requestID else { return }
                clearVoiceSession()
                liveTranscript = ""
                if let microphoneError = error as? MicrophoneCapture.Failure,
                   case .permissionDenied = microphoneError {
                    voiceError = "Allow microphone access in Settings to use voice input."
                } else if error is AssistantError {
                    voiceError = "The app is missing its API configuration."
                } else {
                    voiceError = "Voice transcription is unavailable. Try again or type your request."
                }
            }
        }
    }

    private func stopVoiceInput() {
        guard isRecording else { return }
        isRecording = false
        if let microphone, microphone.isCapturing {
            microphone.stop()
        } else {
            cancelVoiceInput()
        }
    }

    private func clearVoiceSession() {
        voiceTask = nil
        microphone = nil
        voxtral = nil
        isRecording = false
        voiceInputActive = false
    }
#endif

    private func present(_ response: String) {
#if os(watchOS)
        liveTranscript = ""
#endif
        answer = response
        speechOutput.speak(response)
    }

    private static func key(named name: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: name) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}

private enum AssistantError: Error {
    case missingConfiguration
}

@MainActor
protocol SpeechOutput {
    func speak(_ text: String)
    func stop()
}

@MainActor
private final class AppleSpeechOutput: SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
#if os(watchOS)
    private var playbackTask: Task<Void, Never>?
#endif

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestAvailableVoice()
#if os(watchOS)
        playbackTask = Task { [weak self] in
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                let activated = try await session.activate()
                guard !Task.isCancelled else { return }
                guard activated else {
                    print("Speech playback has no available audio route.")
                    return
                }
                self?.synthesizer.speak(utterance)
            } catch {
                print("Speech playback could not activate an audio route: \(error)")
            }
        }
#else
        synthesizer.speak(utterance)
#endif
    }

    func stop() {
#if os(watchOS)
        playbackTask?.cancel()
        playbackTask = nil
#endif
        synthesizer.stopSpeaking(at: .immediate)
    }

    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let primaryLanguage = language.split(separator: "-").first?.lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.split(separator: "-").first?.lowercased() == primaryLanguage
                && !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
        }

        return voices.max { first, second in
            if first.quality != second.quality {
                return first.quality.rawValue < second.quality.rawValue
            }
            let firstMatchesLocale = first.language.caseInsensitiveCompare(language) == .orderedSame
            let secondMatchesLocale = second.language.caseInsensitiveCompare(language) == .orderedSame
            return !firstMatchesLocale && secondMatchesLocale
        } ?? AVSpeechSynthesisVoice(language: language)
    }
}
