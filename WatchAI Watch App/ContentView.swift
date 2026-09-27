import SwiftUI

struct ContentView: View {
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
    }

    private func send() {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        draft = ""
        assistant.submit(request)
    }
}

#Preview {
    ContentView()
}
