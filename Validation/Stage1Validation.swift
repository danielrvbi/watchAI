import Foundation

private final class MockURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, data) = try Self.respond(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
private enum Stage1Validation {
    static func main() async throws {
        checkLanguageDetection()
        try await checkDirectAnswer(question: "What is a black hole?", answer: "A region where gravity traps light.")
        try await checkDirectAnswer(question: "What is 2 plus 3?", answer: "5.")
        try await checkLanguageRequests()
        try await checkConversationMessages()
        try await checkIndependentRequests()
        try await checkSearch(question: "What is the weather in Amsterdam now?", topic: "general")
        try await checkSearch(question: "What is the latest news in Amsterdam?", topic: "news")
        try await checkSearch(
            question: "¿Qué tiempo hace en Madrid ahora?",
            topic: "general",
            language: .spanish,
            answer: "Ahora hace 18 grados."
        )
        try await checkSearchFailure()
        await checkSpeechAndInterruption()
        await checkConversationMemory()
        await checkSpanishQueryFlow()
        await checkSpanishAnswerError()
        await checkStaleResponse()
        await checkModeExitCancellation()
        print("Assistant validation passed: English and Spanish queries, conversation history, search, answer errors, speech, interruption, stale response, mode exit cancellation.")
    }

    private static func checkLanguageDetection() {
        precondition(AssistantLanguage.detect(in: "¿Qué hora es en Madrid?", watchLanguageCode: "en-US") == .spanish)
        precondition(AssistantLanguage.detect(in: "What time is it in Madrid?", watchLanguageCode: "es-ES") == .english)
        precondition(AssistantLanguage.detect(in: "Madrid", watchLanguageCode: "en-US") == .english)
        precondition(AssistantLanguage.detect(in: "Madrid", watchLanguageCode: "es-ES") == .spanish)
        precondition(AssistantLanguage.detect(in: "", watchLanguageCode: "en-US") == .english)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func service(with session: URLSession) -> MistralService {
        MistralService(
            apiKey: "test-mistral",
            tavily: TavilyService(apiKey: "test-tavily", session: session),
            session: session
        )
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                output.append(contentsOf: buffer.prefix(count))
            }
            data = output
        } else {
            throw ValidationError.badRequest
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError.badRequest
        }
        return object
    }

    private static func completion(_ content: String) throws -> Data {
        try json(["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private static func toolCall(query: String, topic: String) throws -> Data {
        let arguments = try json(["query": query, "topic": topic])
        return try json(["choices": [["message": [
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": [[
                "id": "search-1",
                "type": "function",
                "function": ["name": "tavily_search", "arguments": String(decoding: arguments, as: UTF8.self)]
            ]]
        ]]]])
    }

    private static func checkDirectAnswer(question: String, answer: String) async throws {
        let session = session()
        var calls = 0
        MockURLProtocol.respond = { request in
            calls += 1
            precondition(request.url?.host == "api.mistral.ai")
            let requestBody = try body(request)
            precondition((requestBody["tools"] as? [[String: Any]])?.count == 1)
            return (200, try completion(answer))
        }
        let result = try await service(with: session).answer(to: question, language: .english)
        precondition(result == answer && calls == 1)
    }

    private static func checkLanguageRequests() async throws {
        let session = session()
        let requests: [(String, AssistantLanguage)] = [
            ("What time is it?", .english),
            ("¿Qué hora es?", .spanish)
        ]
        var calls = 0
        MockURLProtocol.respond = { request in
            let messages = try body(request)["messages"] as? [[String: Any]] ?? []
            let (query, language) = requests[calls]
            precondition(messages.last?["content"] as? String == query)
            precondition((messages.first?["content"] as? String)?
                .contains("Answer the newest user message in \(language.name)") == true)
            calls += 1
            return (200, try completion(language == .spanish ? "Son las 19:30." : "It is 19:30."))
        }
        let assistant = service(with: session)
        for (query, language) in requests {
            let answer = try await assistant.answer(to: query, language: language)
            precondition(answer == (language == .spanish ? "Son las 19:30." : "It is 19:30."))
        }
        precondition(calls == requests.count)
    }

    private static func checkConversationMessages() async throws {
        let history = [
            ConversationTurn(user: "What is the weather in Madrid?", assistant: "It is 18 degrees."),
            ConversationTurn(user: "Will it rain?", assistant: "No rain is expected.")
        ]
        let latest = "What about tomorrow?"
        let session = session()
        MockURLProtocol.respond = { request in
            let messages = try body(request)["messages"] as? [[String: Any]] ?? []
            precondition(messages.map { $0["role"] as? String } ==
                ["system", "system", "user", "assistant", "user", "assistant", "user"])
            precondition((messages.first?["content"] as? String)?
                .contains("The final user message is the new request") == true)
            precondition(messages.dropFirst(2).compactMap { $0["content"] as? String } == [
                history[0].user, history[0].assistant,
                history[1].user, history[1].assistant,
                latest
            ])
            return (200, try completion("Tomorrow will be dry too."))
        }
        let answer = try await service(with: session).answer(
            to: latest, language: .english, history: history
        )
        precondition(answer == "Tomorrow will be dry too.")
    }

    private static func checkIndependentRequests() async throws {
        let session = session()
        let assistant = service(with: session)
        var calls = 0
        MockURLProtocol.respond = { request in
            calls += 1
            let messages = try body(request)["messages"] as? [[String: Any]] ?? []
            precondition(messages.count == 3)
            precondition(messages.last?["content"] as? String == "Question \(calls)")
            return (200, try completion("Answer \(calls)"))
        }
        let first = try await assistant.answer(to: "Question 1", language: .english)
        let second = try await assistant.answer(to: "Question 2", language: .english)
        precondition(first == "Answer 1" && second == "Answer 2")
    }

    private static func checkSearch(
        question: String,
        topic: String,
        language: AssistantLanguage = .english,
        answer: String = "Current answer from search."
    ) async throws {
        let session = session()
        var mistralCalls = 0
        var tavilyCalls = 0
        MockURLProtocol.respond = { request in
            switch request.url?.host {
            case "api.mistral.ai":
                mistralCalls += 1
                let messages = try body(request)["messages"] as? [[String: Any]] ?? []
                precondition((messages.first?["content"] as? String)?
                    .contains("Answer the newest user message in \(language.name)") == true)
                precondition(messages[2]["content"] as? String == question)
                if mistralCalls == 1 {
                    return (200, try toolCall(query: question, topic: topic))
                }
                precondition(messages.map { $0["role"] as? String } ==
                             ["system", "system", "user", "assistant", "tool"])
                precondition((messages.last?["content"] as? String)?.contains("Test result") == true)
                return (200, try completion(answer))
            case "api.tavily.com":
                tavilyCalls += 1
                let searchBody = try body(request)
                precondition(searchBody["topic"] as? String == topic)
                return (200, try json(["results": [[
                    "title": "Test result",
                    "url": "https://example.com/result",
                    "content": "Current fact",
                    "published_date": "2026-09-27"
                ]]]))
            default:
                throw ValidationError.badRequest
            }
        }
        let result = try await service(with: session).answer(to: question, language: language)
        precondition(result == answer)
        precondition(mistralCalls == 2 && tavilyCalls == 1)
    }

    private static func checkSearchFailure() async throws {
        let session = session()
        var mistralCalls = 0
        MockURLProtocol.respond = { request in
            switch request.url?.host {
            case "api.mistral.ai":
                mistralCalls += 1
                if mistralCalls == 1 {
                    return (200, try toolCall(query: "Weather now", topic: "general"))
                }
                let requestBody = try body(request)
                precondition(requestBody["tools"] == nil)
                let messages = requestBody["messages"] as? [[String: Any]] ?? []
                precondition((messages.last?["content"] as? String)?.contains("Search is unavailable") == true)
                return (200, try completion("I can't check the weather right now. Please try again later."))
            case "api.tavily.com":
                return (500, Data())
            default:
                throw ValidationError.badRequest
            }
        }
        let result = try await service(with: session).answer(to: "Weather now", language: .english)
        precondition(result == "I can't check the weather right now. Please try again later.")
        precondition(mistralCalls == 2)
    }

    @MainActor
    private static func checkSpeechAndInterruption() async {
        let speech = RecordingSpeechOutput()
        let model = AssistantViewModel(
            answerRequest: { request, _, _ in request },
            speechOutput: speech
        )
        model.submit("First answer")
        precondition(model.isLoading)
        for _ in 0..<100 where model.answer != "First answer" { await Task.yield() }
        precondition(model.answer == "First answer")
        precondition(!model.isLoading)
        precondition(speech.spoken == ["First answer"] && speech.stopCount == 1)

        model.submit("Second answer")
        precondition(model.isLoading)
        precondition(speech.stopCount == 2)
        for _ in 0..<100 where model.answer != "Second answer" { await Task.yield() }
        precondition(model.answer == "Second answer")
        precondition(!model.isLoading)
        precondition(speech.spoken == ["First answer", "Second answer"])
        precondition(speech.languages == [.english, .english])
    }

    @MainActor
    private static func checkConversationMemory() async {
        let speech = RecordingSpeechOutput()
        var receivedHistories: [[ConversationTurn]] = []
        let model = AssistantViewModel(
            answerRequest: { request, _, history in
                receivedHistories.append(history)
                return request == "What is the weather in Madrid?"
                    ? "It is 18 degrees." : "Tomorrow will be dry."
            },
            speechOutput: speech
        )
        model.submit("What is the weather in Madrid?")
        for _ in 0..<100 where model.answer == nil { await Task.yield() }
        precondition(model.conversation == [ConversationTurn(
            user: "What is the weather in Madrid?", assistant: "It is 18 degrees."
        )])
        model.cancelCurrentRequest()
        model.submit("What about tomorrow?")
        for _ in 0..<100 where model.answer == nil { await Task.yield() }
        precondition(receivedHistories == [[], [ConversationTurn(
            user: "What is the weather in Madrid?", assistant: "It is 18 degrees."
        )]])
        precondition(model.conversation.count == 2)
        precondition(model.conversation.last == ConversationTurn(
            user: "What about tomorrow?", assistant: "Tomorrow will be dry."
        ))
    }

    @MainActor
    private static func checkSpanishAnswerError() async {
        let speech = RecordingSpeechOutput()
        let model = AssistantViewModel(
            answerRequest: { _, _, _ in throw ValidationError.badRequest },
            speechOutput: speech
        )
        model.submit("¿Qué tiempo hace en Madrid?")
        for _ in 0..<100 where model.answer == nil { await Task.yield() }
        precondition(model.answer == AssistantLanguage.spanish.answerUnavailableMessage)
        precondition(speech.languages == [.spanish])
        precondition(speech.spoken == [AssistantLanguage.spanish.answerUnavailableMessage])
        precondition(model.conversation.isEmpty)
    }

    @MainActor
    private static func checkSpanishQueryFlow() async {
        let question = "¿Qué hora es en Madrid?"
        let speech = RecordingSpeechOutput()
        var receivedQuery: String?
        var receivedLanguage: AssistantLanguage?
        let model = AssistantViewModel(
            answerRequest: { request, language, _ in
                receivedQuery = request
                receivedLanguage = language
                return "Son las 19:30."
            },
            speechOutput: speech
        )
        model.submit(question)
        for _ in 0..<100 where model.answer == nil { await Task.yield() }
        precondition(receivedQuery == question)
        precondition(receivedLanguage == .spanish)
        precondition(model.answer == "Son las 19:30.")
        precondition(speech.spoken == ["Son las 19:30."])
        precondition(speech.languages == [.spanish])
    }

    @MainActor
    private static func checkStaleResponse() async {
        var olderStarted = false
        let speech = RecordingSpeechOutput()
        let model = AssistantViewModel(answerRequest: { request, _, _ in
            if request == "older" {
                olderStarted = true
                try? await Task.sleep(nanoseconds: 200_000_000)
                return "older answer"
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            return "newer answer"
        }, speechOutput: speech)
        model.submit("older")
        precondition(model.isLoading)
        while !olderStarted { await Task.yield() }
        model.submit("newer")
        precondition(model.isLoading)
        try? await Task.sleep(nanoseconds: 300_000_000)
        precondition(model.answer == "newer answer")
        precondition(!model.isLoading)
        precondition(speech.spoken == ["newer answer"])
        precondition(model.conversation == [ConversationTurn(
            user: "newer", assistant: "newer answer"
        )])
    }

    @MainActor
    private static func checkModeExitCancellation() async {
        var requestStarted = false
        let speech = RecordingSpeechOutput()
        let model = AssistantViewModel(answerRequest: { _, _, _ in
            requestStarted = true
            try? await Task.sleep(nanoseconds: 100_000_000)
            return "late answer"
        }, speechOutput: speech)
        model.submit("Question")
        precondition(model.isLoading)
        while !requestStarted { await Task.yield() }
        model.cancelCurrentRequest()
        precondition(!model.isLoading)
        try? await Task.sleep(nanoseconds: 150_000_000)
        precondition(model.answer == nil)
        precondition(speech.spoken.isEmpty)
        precondition(model.conversation.isEmpty)
        precondition(speech.stopCount == 2)
    }
}

@MainActor
private final class RecordingSpeechOutput: SpeechOutput {
    var spoken: [String] = []
    var languages: [AssistantLanguage] = []
    var stopCount = 0

    func speak(_ text: String, language: AssistantLanguage) {
        spoken.append(text)
        languages.append(language)
    }
    func stop() { stopCount += 1 }
}

private enum ValidationError: Error {
    case badRequest
}
