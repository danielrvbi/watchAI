import Foundation

struct MistralService {
    let apiKey: String
    var session: URLSession = .shared

    func complete(messages: [ChatMessage], jsonResponse: Bool = false) async throws -> String {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: "mistral-small-latest",
            messages: messages,
            responseFormat: jsonResponse ? ResponseFormat(type: "json_object") : nil
        ))

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw MistralError.unavailable
        }
        guard let content = try JSONDecoder().decode(ChatResponse.self, from: data)
            .choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw MistralError.invalidResponse
        }
        return content
    }
}

struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private enum MistralError: Error {
    case unavailable
    case invalidResponse
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let responseFormat: ResponseFormat?
    let maxTokens = 350

    enum CodingKeys: String, CodingKey {
        case model, messages
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
    }
}

private struct ResponseFormat: Encodable {
    let type: String
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Reply
    }

    struct Reply: Decodable {
        let content: String?
    }
}
