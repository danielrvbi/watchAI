import AVFAudio
import Foundation

@MainActor
final class MicrophoneCapture {
    enum Failure: Error {
        case permissionDenied
        case audioUnavailable
        case conversionFailed
        case streamOverloaded
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var isTapping = false
    private(set) var isCapturing = false

    func prepare() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw Failure.permissionDenied
        }
        try Task.checkCancellation()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default)
        guard try await audioSession.activate() else {
            throw Failure.audioUnavailable
        }
    }

    func start() throws -> AsyncThrowingStream<Data, Error> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Failure.audioUnavailable
        }

        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(64)) {
            continuation = $0
        }
        guard let continuation else { throw Failure.audioUnavailable }

        try input.installAudioTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { readOnlyBuffer, _ in
            let buffer = AVAudioPCMBuffer(copying: readOnlyBuffer)
            let outputFrames = AVAudioFrameCount(
                ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate)
            ) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrames) else {
                continuation.finish(throwing: Failure.conversionFailed)
                return
            }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil else {
                continuation.finish(throwing: Failure.conversionFailed)
                return
            }
            guard output.frameLength > 0, let samples = output.int16ChannelData?.pointee else {
                return
            }

            // One 16-bit channel, already converted to 16 kHz by AVAudioConverter.
            let data = Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
            if case .dropped = continuation.yield(data) {
                continuation.finish(throwing: Failure.streamOverloaded)
            }
        }
        isTapping = true

        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
            return stream
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if isTapping {
            engine.inputNode.removeTap(onBus: 0)
            isTapping = false
        }
        engine.stop()
        isCapturing = false
        continuation?.finish()
        continuation = nil
    }

    func release() async {
        stop()
        _ = try? await AVAudioSession.sharedInstance().deactivate()
    }
}
