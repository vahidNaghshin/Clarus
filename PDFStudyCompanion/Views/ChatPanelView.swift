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
    let defaultNoteReference: NoteReferenceContext?
    let onAddAssistantMessageToNote: (ChatMessage, NoteReferenceContext?) -> Void
    @ObservedObject var historyStore: InteractionHistoryStore
    @State private var messages: [ChatMessage] = []
    @State private var noteReferencesByMessageID: [UUID: NoteReferenceContext]
    @State private var draft: String = ""
    @State private var errorMessage: String?
    @State private var isSending = false

    init(
        document: PDFDocument,
        section: Section,
        selectedText: String?,
        historyStore: InteractionHistoryStore,
        initialMessages: [ChatMessage] = [],
        defaultNoteReference: NoteReferenceContext? = nil,
        initialNoteReferences: [UUID: NoteReferenceContext] = [:],
        onAddAssistantMessageToNote: @escaping (ChatMessage, NoteReferenceContext?) -> Void
    ) {
        self.document = document
        self.section = section
        self.selectedText = selectedText
        self.initialMessages = initialMessages
        self.defaultNoteReference = defaultNoteReference
        self.onAddAssistantMessageToNote = onAddAssistantMessageToNote
        self.historyStore = historyStore
        _messages = State(initialValue: initialMessages)
        _noteReferencesByMessageID = State(initialValue: initialNoteReferences)
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

                            MarkdownLatexView(text: message.text)

                            if message.role == .assistant {
                                let alreadyAddedToNote = historyStore.notes.contains { $0.sourceChatMessageID == message.id }
                                Button(alreadyAddedToNote ? "Added to note" : "Add this to note") {
                                    onAddAssistantMessageToNote(message, noteReferencesByMessageID[message.id] ?? defaultNoteReference)
                                }
                                .buttonStyle(.link)
                                .disabled(alreadyAddedToNote)
                            }
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

            HStack(alignment: .bottom) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Ask about this section…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $draft)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 1)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 34, maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )

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
            if let noteReference = event.noteReference {
                noteReferencesByMessageID[event.message.id] = noteReference
            }
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
                    if let defaultNoteReference {
                        noteReferencesByMessageID[assistantMessage.id] = defaultNoteReference
                    }
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
