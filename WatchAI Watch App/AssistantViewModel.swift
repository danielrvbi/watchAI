import AVFAudio
import Combine
import Foundation

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var answer: String?

    private let answerRequest: @MainActor (String) async throws -> String
    private let speechOutput: SpeechOutput
    private var activeRequest: Task<Void, Never>?
    private var latestRequestID = UUID()

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
        let requestID = UUID()
        latestRequestID = requestID
        answer = nil

        activeRequest = Task {
            do {
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

    private func present(_ response: String) {
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

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestAvailableVoice()
        synthesizer.speak(utterance)
    }

    func stop() {
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
