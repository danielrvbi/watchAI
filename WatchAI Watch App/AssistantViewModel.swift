import Combine
import Foundation

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var answer: String?

    private let answerRequest: @MainActor (String) async throws -> String
    private var activeRequest: Task<Void, Never>?
    private var latestRequestID = UUID()

    init(answerRequest: (@MainActor (String) async throws -> String)? = nil) {
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
        activeRequest?.cancel()
        let requestID = UUID()
        latestRequestID = requestID
        answer = nil

        activeRequest = Task {
            do {
                let response = try await answerRequest(request)
                guard !Task.isCancelled, latestRequestID == requestID else { return }
                answer = response
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, latestRequestID == requestID else { return }
                answer = error is AssistantError
                    ? "The app is missing its API configuration."
                    : "I couldn't get an answer right now. Please try again."
            }
        }
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
