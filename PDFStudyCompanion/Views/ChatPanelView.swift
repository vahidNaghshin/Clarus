import SwiftUI

extension Notification.Name {
    static let equationCaptureDidGenerateMessage = Notification.Name("equationCaptureDidGenerateMessage")
}

/// Minimal chat UI. Context assembly and retrieval gating happen in
/// ChatService — this view just displays the thread and forwards input.
struct ChatPanelView: View {
    let document: PDFDocument
    let section: Section
    let selectedText: String?
    let initialMessages: [ChatMessage]
    @ObservedObject var historyStore: InteractionHistoryStore
    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""
    @State private var errorMessage: String?
    @State private var isSending = false

    init(
        document: PDFDocument,
        section: Section,
        selectedText: String?,
        historyStore: InteractionHistoryStore,
        initialMessages: [ChatMessage] = []
    ) {
        self.document = document
        self.section = section
        self.selectedText = selectedText
        self.initialMessages = initialMessages
        self.historyStore = historyStore
        _messages = State(initialValue: initialMessages)
    }

    var body: some View {
        VStack(spacing: 12) {
            if let selectedText, !selectedText.isEmpty {
                Text(selectedText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                ForEach(messages) { message in
                    HStack {
                        if message.role == .assistant { Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: 8) {
                            if let imageData = message.imageData,
                               let image = NSImage(data: imageData) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 220, maxHeight: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            Text(message.text)
                        }
                        .padding(10)
                        .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        if message.role == .user { Spacer(minLength: 0) }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                TextField("Ask about this section…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button(isSending ? "Sending…" : "Send") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 520)
        .bedrockStatusBanner()
        .onReceive(NotificationCenter.default.publisher(for: .equationCaptureDidGenerateMessage)) { notification in
            guard let event = notification.object as? EquationChatEvent,
                  event.documentID == document.id,
                  event.sectionID == section.id
            else { return }

            messages.append(event.message)
        }
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let userMessage = ChatMessage(
            id: UUID(),
            documentID: document.id,
            sectionID: section.id,
            role: .user,
            text: prompt,
            imageData: nil,
            timestamp: Date())
        messages.append(userMessage)
        historyStore.addChatMessage(document: document, section: section, role: .user, text: prompt, selectedText: selectedText)
        errorMessage = nil
        isSending = true
        draft = ""

        Task {
            do {
                let llm = BedrockProvider.configured()
                let service = ChatService(
                    llm: llm,
                    embeddingStore: nil,
                    documentID: document.id.uuidString)
                let reply = try await service.send(prompt, selection: selectedText, currentSection: section)

                await MainActor.run {
                    let assistantMessage = ChatMessage(
                        id: UUID(),
                        documentID: document.id,
                        sectionID: section.id,
                        role: .assistant,
                        text: reply,
                        imageData: nil,
                        timestamp: Date())
                    messages.append(assistantMessage)
                    historyStore.addChatMessage(document: document, section: section, role: .assistant, text: reply, selectedText: selectedText)
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }
}
