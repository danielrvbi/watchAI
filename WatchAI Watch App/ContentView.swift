import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                NavigationLink {
                    TypeInputView()
                } label: {
                    Text("Type / Dictate")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                NavigationLink {
                    VoiceInputView()
                } label: {
                    Text("Full Voice")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TypeInputView: View {
    @StateObject private var assistant = AssistantViewModel()
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 8) {
            if let answer = assistant.answer {
                ScrollView {
                    Text(answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
    @StateObject private var assistant = AssistantViewModel()

    var body: some View {
        VStack(spacing: 8) {
            if let answer = assistant.answer {
                ScrollView {
                    Text(answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

#Preview {
    ContentView()
}
