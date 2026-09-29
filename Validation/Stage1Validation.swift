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
        try await checkSearch(
            question: "What about tomorrow?",
            topic: "general",
            history: [ConversationTurn(user: "What is the weather in Madrid?", assistant: "It is 18 degrees.")]
        )
        try await checkSearchFailure()
        try await checkInvalidRoutes()
        try await checkSearchStateIsEphemeral()
        await checkSpeechAndInterruption()
        await checkConversationMemory()
        await checkSpanishQueryFlow()
        await checkSpanishAnswerError()
        await checkInvalidRouteViewModel()
        await checkStaleResponse()
        await checkModeExitCancellation()
        print("Assistant validation passed: routing, English and Spanish answers, conversation history, search and failures, ephemeral results, speech, interruption, stale response, and cancellation.")
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

    private static func chain(with session: URLSession) -> MiniChain {
        MiniChain(
            mistral: MistralService(apiKey: "test-mistral", session: session),
            tavily: TavilyService(apiKey: "test-tavily", session: session)
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

    private static func routeCompletion(query: String? = nil, topic: String? = nil) throws -> Data {
        let route: [String: Any] = [
            "webSearch": query != nil,
            "tavilyQuery": query ?? NSNull(),
            "tavilyTopic": topic ?? NSNull()
        ]
        return try completion(String(decoding: json(route), as: UTF8.self))
    }

    private static func isRouteRequest(_ requestBody: [String: Any]) -> Bool {
        (requestBody["response_format"] as? [String: String])?["type"] == "json_object"
    }

    private static func assertNoTools(_ requestBody: [String: Any]) {
        precondition(requestBody["tools"] == nil)
        precondition(requestBody["tool_choice"] == nil)
    }

    private static func checkDirectAnswer(question: String, answer: String) async throws {
        let session = session()
        var calls = 0
        MockURLProtocol.respond = { request in
            calls += 1
            precondition(request.url?.host == "api.mistral.ai")
            let requestBody = try body(request)
            assertNoTools(requestBody)
            let messages = requestBody["messages"] as? [[String: Any]] ?? []
            precondition(messages.last?["content"] as? String == question)
            if calls == 1 {
                precondition(isRouteRequest(requestBody))
                precondition((messages.first?["content"] as? String)?.contains("JSON object") == true)
                return (200, try routeCompletion())
            }
            precondition(calls == 2 && !isRouteRequest(requestBody))
            precondition(requestBody["response_format"] == nil)
            precondition(messages.map { $0["role"] as? String } == ["system", "system", "user"])
            precondition((messages.first?["content"] as? String)?
                .contains("name the specific result's publisher or site") == false)
            precondition((messages[1]["content"] as? String)?.contains("Current local date and time") == true)
            return (200, try completion(answer))
        }
        let result = try await chain(with: session).invoke(
            userMessage: question, history: [], language: .english
        )
        precondition(result == answer && calls == 2)
    }

    private static func checkLanguageRequests() async throws {
        let session = session()
        let requests: [(String, AssistantLanguage)] = [
            ("What time is it?", .english),
            ("¿Qué hora es?", .spanish)
        ]
        var calls = 0
        MockURLProtocol.respond = { request in
            let requestBody = try body(request)
            let messages = requestBody["messages"] as? [[String: Any]] ?? []
            let (query, language) = requests[calls / 2]
            precondition(messages.last?["content"] as? String == query)
            calls += 1
            if isRouteRequest(requestBody) {
                precondition(calls % 2 == 1)
                return (200, try routeCompletion())
            }
            precondition(calls % 2 == 0)
            precondition((messages.first?["content"] as? String)?
                .contains("Answer the newest user message in \(language.name)") == true)
            return (200, try completion(language == .spanish ? "Son las 19:30." : "It is 19:30."))
        }
        let assistant = chain(with: session)
        for (query, language) in requests {
            let answer = try await assistant.invoke(userMessage: query, history: [], language: language)
            precondition(answer == (language == .spanish ? "Son las 19:30." : "It is 19:30."))
        }
        precondition(calls == requests.count * 2)
    }

    private static func checkConversationMessages() async throws {
        let history = [
            ConversationTurn(user: "What is the weather in Madrid?", assistant: "It is 18 degrees."),
            ConversationTurn(user: "Will it rain?", assistant: "No rain is expected.")
        ]
        let latest = "What about tomorrow?"
        let session = session()
        var calls = 0
        MockURLProtocol.respond = { request in
            calls += 1
            let requestBody = try body(request)
            let messages = requestBody["messages"] as? [[String: Any]] ?? []
            let historyStart = isRouteRequest(requestBody) ? 1 : 2
            precondition(messages.dropFirst(historyStart).compactMap { $0["content"] as? String } == [
                history[0].user, history[0].assistant,
                history[1].user, history[1].assistant,
                latest
            ])
            if isRouteRequest(requestBody) {
                precondition(messages.map { $0["role"] as? String } ==
                    ["system", "user", "assistant", "user", "assistant", "user"])
                return (200, try routeCompletion())
            }
            precondition(messages.map { $0["role"] as? String } ==
                ["system", "system", "user", "assistant", "user", "assistant", "user"])
            precondition((messages.first?["content"] as? String)?
                .contains("The final user message is the new request") == true)
            return (200, try completion("Tomorrow will be dry too."))
        }
        let answer = try await chain(with: session).invoke(
            userMessage: latest, history: history, language: .english
        )
        precondition(answer == "Tomorrow will be dry too." && calls == 2)
    }

    private static func checkIndependentRequests() async throws {
        let session = session()
        let assistant = chain(with: session)
        var calls = 0
        MockURLProtocol.respond = { request in
            calls += 1
            let requestBody = try body(request)
            let messages = requestBody["messages"] as? [[String: Any]] ?? []
            precondition(messages.last?["content"] as? String == "Question \((calls + 1) / 2)")
            if isRouteRequest(requestBody) {
                precondition(messages.count == 2)
                return (200, try routeCompletion())
            }
            precondition(messages.count == 3)
            return (200, try completion("Answer \(calls / 2)"))
        }
        let first = try await assistant.invoke(userMessage: "Question 1", history: [], language: .english)
        let second = try await assistant.invoke(userMessage: "Question 2", history: [], language: .english)
        precondition(first == "Answer 1" && second == "Answer 2" && calls == 4)
    }

    private static func checkSearch(
        question: String,
        topic: String,
        language: AssistantLanguage = .english,
        answer: String = "Current answer from search.",
        history: [ConversationTurn] = []
    ) async throws {
        let session = session()
        var mistralCalls = 0
        var tavilyCalls = 0
        MockURLProtocol.respond = { request in
            switch request.url?.host {
            case "api.mistral.ai":
                mistralCalls += 1
                let requestBody = try body(request)
                assertNoTools(requestBody)
                let messages = requestBody["messages"] as? [[String: Any]] ?? []
                precondition(messages.last?["content"] as? String == question)
                if mistralCalls == 1 {
                    precondition(isRouteRequest(requestBody))
                    precondition(messages.count == 2 + history.count * 2)
                    precondition(messages.dropFirst().dropLast().compactMap { $0["content"] as? String } ==
                        history.flatMap { [$0.user, $0.assistant] })
                    return (200, try routeCompletion(query: question, topic: topic))
                }
                precondition(!isRouteRequest(requestBody))
                precondition(messages.map { $0["role"] as? String } ==
                    ["system", "system", "system"] +
                    Array(repeating: ["user", "assistant"], count: history.count).flatMap { $0 } + ["user"])
                precondition((messages.first?["content"] as? String)?
                    .contains("Answer the newest user message in \(language.name)") == true)
                precondition((messages.first?["content"] as? String)?
                    .contains("name the specific result's publisher or site") == true)
                precondition((messages.first?["content"] as? String)?
                    .contains("do not present an older value as current") == true)
                precondition((messages[2]["content"] as? String)?.contains("Test result") == true)
                precondition((messages[2]["content"] as? String)?.contains("2026-09-27") == true)
                precondition(messages.dropFirst(3).dropLast().compactMap { $0["content"] as? String } ==
                    history.flatMap { [$0.user, $0.assistant] })
                return (200, try completion(answer))
            case "api.tavily.com":
                tavilyCalls += 1
                let searchBody = try body(request)
                precondition(searchBody["query"] as? String == question)
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
        let result = try await chain(with: session).invoke(
            userMessage: question, history: history, language: language
        )
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
                    let requestBody = try body(request)
                    precondition(isRouteRequest(requestBody))
                    return (200, try routeCompletion(query: "Weather now", topic: "general"))
                }
                let requestBody = try body(request)
                precondition(!isRouteRequest(requestBody))
                let messages = requestBody["messages"] as? [[String: Any]] ?? []
                precondition((messages[2]["content"] as? String)?.contains("Search is unavailable") == true)
                precondition(messages.last?["content"] as? String == "Weather now")
                return (200, try completion("I can't check the weather right now. Please try again later."))
            case "api.tavily.com":
                return (500, Data())
            default:
                throw ValidationError.badRequest
            }
        }
        let result = try await chain(with: session).invoke(
            userMessage: "Weather now", history: [], language: .english
        )
        precondition(result == "I can't check the weather right now. Please try again later.")
        precondition(mistralCalls == 2)
    }

    private static func checkInvalidRoutes() async throws {
        let invalidReplies = [
            "not JSON",
            #"{"webSearch":false}"#,
            #"{"webSearch":true,"tavilyQuery":"Weather now"}"#,
            #"{"webSearch":true,"tavilyQuery":"  ","tavilyTopic":"general"}"#,
            #"{"webSearch":true,"tavilyQuery":"Weather now","tavilyTopic":"invalid"}"#,
            #"{"webSearch":false,"tavilyQuery":"Weather now","tavilyTopic":null}"#
        ]
        for reply in invalidReplies {
            let session = session()
            var calls = 0
            MockURLProtocol.respond = { request in
                calls += 1
                precondition(request.url?.host == "api.mistral.ai")
                let requestBody = try body(request)
                precondition(isRouteRequest(requestBody))
                return (200, try completion(reply))
            }
            do {
                _ = try await chain(with: session).invoke(
                    userMessage: "Question", history: [], language: .english
                )
                preconditionFailure("Invalid route was accepted")
            } catch {
                precondition(calls == 1)
            }
        }
    }

    private static func checkSearchStateIsEphemeral() async throws {
        let session = session()
        let chain = chain(with: session)
        var mistralCalls = 0
        var tavilyCalls = 0
        MockURLProtocol.respond = { request in
            switch request.url?.host {
            case "api.mistral.ai":
                mistralCalls += 1
                let requestBody = try body(request)
                let messages = requestBody["messages"] as? [[String: Any]] ?? []
                if mistralCalls >= 3 {
                    precondition(!messages.contains {
                        ($0["content"] as? String)?.contains("SECRET_SEARCH_TOKEN") == true
                    })
                    precondition(messages.dropLast().compactMap { $0["content"] as? String }
                        .contains("First answer."))
                }
                switch mistralCalls {
                case 1:
                    precondition(isRouteRequest(requestBody))
                    return (200, try routeCompletion(query: "Weather now", topic: "general"))
                case 2:
                    precondition(!isRouteRequest(requestBody))
                    precondition(messages.contains {
                        ($0["content"] as? String)?.contains("SECRET_SEARCH_TOKEN") == true
                    })
                    return (200, try completion("First answer."))
                case 3:
                    precondition(isRouteRequest(requestBody))
                    return (200, try routeCompletion())
                case 4:
                    precondition(!isRouteRequest(requestBody))
                    return (200, try completion("Second answer."))
                default:
                    throw ValidationError.badRequest
                }
            case "api.tavily.com":
                tavilyCalls += 1
                return (200, try json(["results": [[
                    "title": "SECRET_SEARCH_TOKEN",
                    "url": "https://example.com/weather",
                    "content": "Current fact"
                ]]]))
            default:
                throw ValidationError.badRequest
            }
        }
        let first = try await chain.invoke(
            userMessage: "Weather now", history: [], language: .english
        )
        let second = try await chain.invoke(
            userMessage: "And a general question?",
            history: [ConversationTurn(user: "Weather now", assistant: first)],
            language: .english
        )
        precondition(first == "First answer." && second == "Second answer.")
        precondition(mistralCalls == 4 && tavilyCalls == 1)
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
    private static func checkInvalidRouteViewModel() async {
        let session = session()
        let assistant = chain(with: session)
        MockURLProtocol.respond = { request in
            precondition(request.url?.host == "api.mistral.ai")
            return (200, try completion(#"{"webSearch":true,"tavilyQuery":"","tavilyTopic":"general"}"#))
        }
        let speech = RecordingSpeechOutput()
        let model = AssistantViewModel(answerRequest: { request, language, history in
            try await assistant.invoke(userMessage: request, history: history, language: language)
        }, speechOutput: speech)
        model.submit("What is the weather now?")
        for _ in 0..<100 where model.answer == nil { await Task.yield() }
        precondition(model.answer == AssistantLanguage.english.answerUnavailableMessage)
        precondition(model.conversation.isEmpty)
        precondition(speech.spoken == [AssistantLanguage.english.answerUnavailableMessage])
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
