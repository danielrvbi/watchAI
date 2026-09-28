import Foundation

@MainActor
final class VoxtralRealtimeService {
    enum Failure: Error {
        case connection
        case transcription
        case invalidEvent
    }

    private let apiKey: String
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<String, Error>?
    private var onDelta: ((String) -> Void)?
    private var onFailure: (() -> Void)?
    private var accumulatedText = ""

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func connect(
        onDelta: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) async throws {
        self.onDelta = onDelta
        self.onFailure = onFailure

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        self.session = session

        var request = URLRequest(url: URL(string:
            "wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=voxtral-mini-transcribe-realtime-2602"
        )!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.networkServiceType = .avStreaming
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        let timeout = timeoutTask(seconds: 12)
        defer { timeout.cancel() }
        do {
            // The server announces the session before it accepts an audio format update.
            while true {
                let event = try await receiveEvent()
                switch event.type {
                case "session.created":
                    break
                case "error":
                    throw Failure.connection
                default:
                    continue
                }
                break
            }
            try await send([
                "type": "session.update",
                "session": [
                    "audio_format": ["encoding": "pcm_s16le", "sample_rate": 16_000]
                ]
            ])
        } catch {
            cancel()
            throw Failure.connection
        }

        receiver = Task {
            do {
                return try await receiveUntilDone()
            } catch {
                if !Task.isCancelled { onFailure() }
                throw error
            }
        }
    }

    func stream(_ chunks: AsyncThrowingStream<Data, Error>) async throws {
        for try await chunk in chunks {
            try Task.checkCancellation()
            try await send([
                "type": "input_audio.append",
                "audio": chunk.base64EncodedString()
            ])
        }
    }

    func finish() async throws -> String {
        try await send(["type": "input_audio.flush"])
        try await send(["type": "input_audio.end"])

        guard let receiver else { throw Failure.connection }
        let timeout = timeoutTask(seconds: 20)
        defer { timeout.cancel() }
        return try await receiver.value
    }

    func cancel() {
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        onDelta = nil
        onFailure = nil
    }

    private func receiveUntilDone() async throws -> String {
        while true {
            try Task.checkCancellation()
            let event = try await receiveEvent()
            switch event.type {
            case "transcription.text.delta":
                guard let text = event.payload["text"] as? String else {
                    throw Failure.invalidEvent
                }
                accumulatedText += text
                onDelta?(text)
            case "transcription.done":
                guard let text = event.payload["text"] as? String else {
                    throw Failure.invalidEvent
                }
                return text
            case "error":
                throw Failure.transcription
            default:
                break
            }
        }
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw Failure.connection }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveEvent() async throws -> (type: String, payload: [String: Any]) {
        guard let socket else { throw Failure.connection }
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw Failure.invalidEvent
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw Failure.invalidEvent
        }
        return (type, object)
    }

    private func timeoutTask(seconds: UInt64) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.socket?.cancel(with: .goingAway, reason: nil)
        }
    }
}
