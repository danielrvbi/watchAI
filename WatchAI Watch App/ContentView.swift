import SwiftUI

struct ContentView: View {
    @StateObject private var assistant = AssistantViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                NavigationLink {
                    TypeInputView(assistant: assistant)
                } label: {
                    Text("Type / Dictate")
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxHeight: .infinity)
                .buttonStyle(.plain)

                NavigationLink {
                    VoiceInputView(assistant: assistant)
                } label: {
                    Text("Full Voice")
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxHeight: .infinity)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TypeInputView: View {
    @ObservedObject var assistant: AssistantViewModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 8) {
            if let answer = assistant.answer {
                ScrollView {
                    Text(answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if assistant.isLoading {
                ThinkingView()
            } else {
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                TextField("Ask", text: $draft)
                    .submitLabel(.send)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                }
                .accessibilityLabel("Send")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 8)
        .onDisappear { assistant.cancelCurrentRequest() }
    }

    private func send() {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        draft = ""
        assistant.submit(request)
    }
}

private struct VoiceInputView: View {
    @ObservedObject var assistant: AssistantViewModel

    var body: some View {
        VStack(spacing: 8) {
            if let answer = assistant.answer {
                ScrollView {
                    Text(answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if assistant.isLoading {
                ThinkingView()
            } else if !assistant.liveTranscript.isEmpty {
                ScrollView {
                    Text(assistant.liveTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let voiceError = assistant.voiceError {
                ScrollView {
                    Text(voiceError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer(minLength: 0)
            }

            if assistant.isRecording ||
                (!assistant.voiceInputActive && assistant.liveTranscript.isEmpty) {
                Button(action: assistant.toggleVoiceInput) {
                    Image(systemName: assistant.isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(assistant.isRecording ? "Stop recording" : "Start recording")
            }
        }
        .padding(.horizontal, 8)
        .onDisappear { assistant.cancelCurrentRequest() }
    }
}

private struct ThinkingView: View {
    @State private var startDate = Date()
    private let frameCount = 9
    private let frameDuration = 0.12

    var body: some View {
        TimelineView(.periodic(from: startDate, by: frameDuration)) { timeline in
            let step = max(0, Int(timeline.date.timeIntervalSince(startDate) / frameDuration))
            let cycle = 2 * (frameCount - 1)
            let position = step % cycle
            let frame = position < frameCount ? position + 1 : cycle - position + 1

            VStack(spacing: 4) {
                Image("loading_frames/loading_frame\(frame)")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 150, maxHeight: 82)
                    .accessibilityHidden(true)

                Text("Thinking…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Thinking")
        }
    }
}

#Preview {
    ContentView()
}
