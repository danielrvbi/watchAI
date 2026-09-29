import AVFAudio
import Foundation
import NaturalLanguage

enum AssistantLanguage: Equatable {
    case english
    case spanish

    static func detect(
        in request: String,
        watchLanguageCode: String = AVSpeechSynthesisVoice.currentLanguageCode()
    ) -> Self {
        let fallback: Self = watchLanguageCode.lowercased().hasPrefix("es") ? .spanish : .english
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(request)

        let probabilities = recognizer.languageHypotheses(withMaximum: 2)
        guard let candidate = probabilities.max(by: { $0.value < $1.value }),
              let language = Self(naturalLanguage: candidate.key) else { return fallback }

        let wordCount = request.split(whereSeparator: { !$0.isLetter }).count
        let minimumConfidence = wordCount < 2 ? 0.97 : 0.75
        let otherConfidence = probabilities
            .filter { $0.key != candidate.key }
            .map(\.value)
            .max() ?? 0
        guard candidate.value >= minimumConfidence,
              candidate.value - otherConfidence >= 0.3 else { return fallback }
        return language
    }

    private init?(naturalLanguage: NLLanguage) {
        switch naturalLanguage {
        case .english: self = .english
        case .spanish: self = .spanish
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        }
    }

    var code: String {
        switch self {
        case .english: "en"
        case .spanish: "es"
        }
    }

    var defaultVoiceCode: String {
        switch self {
        case .english: "en-US"
        case .spanish: "es-ES"
        }
    }

    var missingConfigurationMessage: String {
        switch self {
        case .english: "The app is missing its API configuration."
        case .spanish: "Falta la configuración de la API de la aplicación."
        }
    }

    var answerUnavailableMessage: String {
        switch self {
        case .english: "I couldn't get an answer right now. Please try again."
        case .spanish: "No pude obtener una respuesta ahora. Inténtalo de nuevo."
        }
    }
}
