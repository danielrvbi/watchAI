import Foundation

struct ConversationTurn: Equatable {
    let user: String
    let assistant: String
}

struct MistralService {
    let apiKey: String
    let tavily: TavilyService
    var session: URLSession = .shared

    func answer(
        to request: String,
        language: AssistantLanguage,
        history: [ConversationTurn] = []
    ) async throws -> String {
        var messages = [
            ChatMessage(
                role: "system",
                content: Self.systemPrompt + "\n\nAnswer the newest user message in \(language.name), including after using a tool or when a tool fails."
            ),
            ChatMessage(role: "system", content: Self.currentTime)
        ]
        for turn in history {
            messages.append(ChatMessage(role: "user", content: turn.user))
            messages.append(ChatMessage(role: "assistant", content: turn.assistant))
        }
        messages.append(ChatMessage(role: "user", content: request))
        var searchAvailable = true

        // Tool messages stay in this request; the view model retains completed turns.
        for _ in 0..<4 {
            try Task.checkCancellation()
            let reply = try await complete(messages: messages, allowSearch: searchAvailable)
            let calls = reply.toolCalls ?? []
            if calls.isEmpty {
                guard let content = reply.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { throw MistralError.invalidResponse }
                return content
            }

            messages.append(ChatMessage(role: "assistant", content: reply.content, toolCalls: calls))
            for call in calls {
                guard call.function.name == "tavily_search",
                      let arguments = call.function.arguments.data(using: .utf8),
                      let search = try? JSONDecoder().decode(SearchArguments.self, from: arguments),
                      !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MistralError.invalidResponse
                }

                let result: String
                do {
                    result = try await tavily.search(
                        query: search.query,
                        topic: search.topic ?? "general"
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    searchAvailable = false
                    result = #"{"error":"Search is unavailable. Do not invent current facts; answer briefly and honestly."}"#
                }
                try Task.checkCancellation()
                messages.append(ChatMessage(
                    role: "tool",
                    content: result,
                    name: call.function.name,
                    toolCallID: call.id
                ))
            }
        }
        throw MistralError.invalidResponse
    }

    private func complete(messages: [ChatMessage], allowSearch: Bool) async throws -> ChatMessage {
        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: "mistral-small-latest",
            messages: messages,
            tools: allowSearch ? [.tavilySearch] : nil,
            toolChoice: allowSearch ? "auto" : nil
        ))

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw MistralError.unavailable
        }
        guard let message = try JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message else {
            throw MistralError.invalidResponse
        }
        return message
    }

    private static var currentTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return "Current local date and time: \(formatter.string(from: Date()))."
    }

    private static let systemPrompt = """
    You are a voice-first assistant for a user whose only device is an Apple Watch with cellular. Everything you say is spoken aloud or read on a tiny screen.

    Output rules:
    - Keep answers under 40 words unless the user explicitly asks for detail.
    - Plain sentences only. No markdown, tables, bullet points, or emoji.
    - Front-load the answer: the key fact or number first, context after.
    - Always use metric units and degrees Celsius. Always use the 24-hour clock (for example, 19:30, not 7:30 PM).
    - Spell out anything a listener needs: say "15 degrees" not "15°C". Say times naturally, for example "19:30" or "half past seven".
    - If a number matters, say it once and stop. Don't repeat or hedge.

    Input rules:
    - Earlier user and assistant messages are conversation history. The final user message is the new request. Use relevant history to understand follow-up questions, and answer only the new request.
    - The user may be dictating. If a word seems wrong or a request is ambiguous, ask ONE short clarifying question instead of guessing. Never ask more than one question per turn.
    - If the request is unanswerable, say so in one sentence and suggest the single best alternative action.

    Tool rules:
    - Web search: only for time-sensitive facts (weather, news, prices, opening hours, sports scores, transit). Never for general knowledge, math, or advice.
    - Code interpreter: only for multi-step calculations, conversions, or anything you can't compute reliably in your head. For trivial math (tips, sums, percentages), just answer.
    - When converting or calculating, work in metric by default. If the user gives imperial units, convert to metric in your answer unless they ask otherwise.
    - If a tool fails or returns nothing useful, give your best answer from your own knowledge and say it may be outdated.

    Reasoning:
    - Think through the problem internally before answering. Never reveal your steps, thinking, or uncertainty — output only the final answer.
    """
}

private enum MistralError: Error {
    case unavailable
    case invalidResponse
}

private struct SearchArguments: Decodable {
    let query: String
    let topic: String?
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let tools: [ToolDefinition]?
    let toolChoice: String?
    let maxTokens = 350

    enum CodingKeys: String, CodingKey {
        case model, messages, tools
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
    }
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String?
    var toolCalls: [ToolCall]? = nil
    var name: String? = nil
    var toolCallID: String? = nil

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

private struct ToolCall: Codable {
    let id: String
    let type: String
    let function: FunctionCall
}

private struct FunctionCall: Codable {
    let name: String
    let arguments: String
}

private struct ToolDefinition: Encodable {
    let type = "function"
    let function: FunctionDefinition

    static let tavilySearch = ToolDefinition(function: FunctionDefinition(
        name: "tavily_search",
        description: "Search the web only for time-sensitive facts such as current weather, news, prices, opening hours, sports scores, or transit. Do not use for general knowledge, math, or advice.",
        parameters: FunctionParameters(
            type: "object",
            properties: [
                "query": Property(type: "string", description: "A concise web search query."),
                "topic": Property(type: "string", description: "Use news for current news, otherwise general.", enumValues: ["general", "news"])
            ],
            required: ["query"]
        )
    ))
}

private struct FunctionDefinition: Encodable {
    let name: String
    let description: String
    let parameters: FunctionParameters
}

private struct FunctionParameters: Encodable {
    let type: String
    let properties: [String: Property]
    let required: [String]
}

private struct Property: Encodable {
    let type: String
    let description: String
    var enumValues: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }
}
