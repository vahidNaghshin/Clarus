import Combine
import Foundation

@MainActor
final class InteractionHistoryStore: ObservableObject {
    @Published private(set) var records: [InteractionRecord] = []
    @Published private(set) var notes: [Note] = []
    @Published private(set) var highlights: [PersistedHighlight] = []
    @Published private(set) var chatMessages: [ChatMessage] = []

    private let fileManager: FileManager
    private let rootDirectoryURL: URL
    private var currentDocumentKey: String?

    private struct InteractionHistoryPayload: Codable {
        var records: [InteractionRecord]
        var notes: [Note]
        var highlights: [PersistedHighlight]
        var chatMessages: [ChatMessage]
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "PDFStudyCompanion"
        rootDirectoryURL = baseDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("InteractionHistory", isDirectory: true)

        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
    }

    func load(document: PDFDocument?) {
        guard let document else {
            currentDocumentKey = nil
            records = []
            notes = []
            highlights = []
            chatMessages = []
            return
        }

        let documentKey = self.documentKey(for: document)
        currentDocumentKey = documentKey

        let payload = loadPayload(for: documentKey)
        records = payload.records.sorted { $0.createdAt > $1.createdAt }
        notes = payload.notes.sorted { $0.createdAt > $1.createdAt }
        highlights = payload.highlights.sorted { $0.createdAt > $1.createdAt }
        chatMessages = payload.chatMessages.sorted { $0.timestamp < $1.timestamp }
    }

    func addSummary(document: PDFDocument, section: Section, summary: Summary) {
        append(
            InteractionRecord(
                id: UUID(),
                documentKey: documentKey(for: document),
                sectionID: section.id,
                sectionTitle: section.title,
                kind: .summary,
                title: "Summary of \(section.title)",
                body: summary.text,
                createdAt: summary.generatedAt,
                relatedQuestionID: nil,
                options: nil,
                selectedAnswerIndex: nil,
                correctAnswerIndex: nil,
                structuralReviewItems: nil))
    }

    func addChatMessage(document: PDFDocument, section: Section, role: ChatMessage.Role, text: String, selectedText: String?, imageData: Data? = nil) {
        let message = ChatMessage(
            id: UUID(),
            documentID: document.id,
            sectionID: section.id,
            role: role,
            text: text,
            imageData: imageData,
            timestamp: Date())
        appendChatMessage(message, documentKey: documentKey(for: document))

        let prefix = selectedText.flatMap { $0.isEmpty ? nil : "Selection: \($0)\n\n" } ?? ""
        append(
            InteractionRecord(
                id: UUID(),
                documentKey: documentKey(for: document),
                sectionID: section.id,
                sectionTitle: section.title,
                kind: role == .user ? .chatPrompt : .chatReply,
                title: role == .user ? "Chat question for \(section.title)" : "Chat answer for \(section.title)",
                body: prefix + text,
                createdAt: Date(),
                relatedQuestionID: nil,
                options: nil,
                selectedAnswerIndex: nil,
                correctAnswerIndex: nil,
                structuralReviewItems: nil))
    }

    func chatHistory(document: PDFDocument, section: Section) -> [ChatMessage] {
        let documentKey = documentKey(for: document)

        let sourceMessages: [ChatMessage]
        if currentDocumentKey == documentKey {
            sourceMessages = chatMessages
        } else {
            sourceMessages = loadPayload(for: documentKey).chatMessages.sorted { $0.timestamp < $1.timestamp }
        }

        return sourceMessages.filter { $0.sectionID == section.id }
    }

    func addStructuralReview(document: PDFDocument, section: Section, review: StructuralReview) {
        append(
            InteractionRecord(
                id: UUID(),
                documentKey: documentKey(for: document),
                sectionID: section.id,
                sectionTitle: section.title,
                kind: .structuralReview,
                title: "Structural review for \(section.title)",
                body: "Generated \(review.items.count) Socratic prompts.",
                createdAt: review.generatedAt,
                relatedQuestionID: nil,
                options: nil,
                selectedAnswerIndex: nil,
                correctAnswerIndex: nil,
                structuralReviewItems: review.items))
    }

    func addQuestions(document: PDFDocument, section: Section, questions: [MultipleChoiceQuestion]) {
        let documentKey = documentKey(for: document)

        for question in questions {
            upsertQuestionRecord(
                documentKey: documentKey,
                section: section,
                question: question)
        }

        persistIfCurrent(documentKey: documentKey)
    }

    func updateQuestionAnswer(document: PDFDocument, section: Section, question: MultipleChoiceQuestion) {
        let documentKey = documentKey(for: document)
        upsertQuestionRecord(documentKey: documentKey, section: section, question: question)
        persistIfCurrent(documentKey: documentKey)
    }

    func addNote(document: PDFDocument, section: Section?, highlightID: UUID?, selectedText: String?, pageIndex: Int?, text: String, sourceChatMessageID: UUID? = nil) {
        let note = Note(
            id: UUID(),
            documentID: document.id,
            sectionID: section?.id,
            sectionTitle: section?.title,
            highlightID: highlightID,
            selectedText: selectedText,
            pageIndex: pageIndex,
            text: text,
            sourceChatMessageID: sourceChatMessageID,
            createdAt: Date())

        let documentKey = documentKey(for: document)
        var payload = loadPayload(for: documentKey)
        payload.notes.insert(note, at: 0)
        save(payload, for: documentKey)

        if currentDocumentKey == documentKey {
            notes = payload.notes.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func addHighlight(document: PDFDocument, section: Section?, selectedText: String?, segments: [HighlightSegment]) -> PersistedHighlight {
        let highlight = PersistedHighlight(
            id: UUID(),
            documentID: document.id,
            sectionID: section?.id,
            sectionTitle: section?.title,
            selectedText: selectedText,
            segments: segments,
            createdAt: Date())

        let documentKey = documentKey(for: document)
        var payload = loadPayload(for: documentKey)
        payload.highlights.insert(highlight, at: 0)
        save(payload, for: documentKey)

        if currentDocumentKey == documentKey {
            highlights = payload.highlights.sorted { $0.createdAt > $1.createdAt }
        }

        return highlight
    }

    func removeHighlight(document: PDFDocument, highlightID: UUID) {
        let documentKey = documentKey(for: document)
        var payload = loadPayload(for: documentKey)
        payload.highlights.removeAll { $0.id == highlightID }
        payload.notes.removeAll { $0.highlightID == highlightID }
        save(payload, for: documentKey)

        if currentDocumentKey == documentKey {
            notes = payload.notes.sorted { $0.createdAt > $1.createdAt }
            highlights = payload.highlights.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func append(_ record: InteractionRecord) {
        let documentKey = record.documentKey
        if currentDocumentKey == documentKey {
            records.insert(record, at: 0)
        }

        var payload = loadPayload(for: documentKey)
        payload.records.insert(record, at: 0)
        save(payload, for: documentKey)
    }

    private func upsertQuestionRecord(documentKey: String, section: Section, question: MultipleChoiceQuestion) {
        var payload = loadPayload(for: documentKey)
        var existing = payload.records

        if let index = existing.firstIndex(where: { $0.relatedQuestionID == question.id }) {
            existing[index].title = "Question for \(section.title)"
            existing[index].body = question.prompt
            existing[index].sectionID = section.id
            existing[index].sectionTitle = section.title
            existing[index].options = question.options
            existing[index].selectedAnswerIndex = question.userAnswerIndex
            existing[index].correctAnswerIndex = question.correctIndex
            existing[index].structuralReviewItems = nil
        } else {
            existing.insert(
                InteractionRecord(
                    id: UUID(),
                    documentKey: documentKey,
                    sectionID: section.id,
                    sectionTitle: section.title,
                    kind: .question,
                    title: "Question for \(section.title)",
                    body: question.prompt,
                    createdAt: Date(),
                    relatedQuestionID: question.id,
                    options: question.options,
                    selectedAnswerIndex: question.userAnswerIndex,
                    correctAnswerIndex: question.correctIndex,
                    structuralReviewItems: nil),
                at: 0)
        }

        payload.records = existing
        save(payload, for: documentKey)

        if currentDocumentKey == documentKey {
            records = existing.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func persistIfCurrent(documentKey: String) {
        guard currentDocumentKey == documentKey else { return }
        let payload = loadPayload(for: documentKey)
        records = payload.records.sorted { $0.createdAt > $1.createdAt }
        notes = payload.notes.sorted { $0.createdAt > $1.createdAt }
        highlights = payload.highlights.sorted { $0.createdAt > $1.createdAt }
        chatMessages = payload.chatMessages.sorted { $0.timestamp < $1.timestamp }
    }

    private func loadPayload(for documentKey: String) -> InteractionHistoryPayload {
        let fileURL = storageFileURL(for: documentKey)
        guard let data = try? Data(contentsOf: fileURL) else {
            return InteractionHistoryPayload(records: [], notes: [], highlights: [], chatMessages: [])
        }

        if let decoded = try? JSONDecoder().decode(InteractionHistoryPayload.self, from: data) {
            return decoded
        }

        struct LegacyPayload: Codable {
            var records: [InteractionRecord]
            var notes: [Note]
            var highlights: [PersistedHighlight]
        }

        if let legacyPayload = try? JSONDecoder().decode(LegacyPayload.self, from: data) {
            return InteractionHistoryPayload(
                records: legacyPayload.records,
                notes: legacyPayload.notes,
                highlights: legacyPayload.highlights,
                chatMessages: [])
        }

        if let legacyRecords = try? JSONDecoder().decode([InteractionRecord].self, from: data) {
            return InteractionHistoryPayload(records: legacyRecords, notes: [], highlights: [], chatMessages: [])
        }

        return InteractionHistoryPayload(records: [], notes: [], highlights: [], chatMessages: [])
    }

    private func save(_ payload: InteractionHistoryPayload, for documentKey: String) {
        let fileURL = storageFileURL(for: documentKey)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func appendChatMessage(_ message: ChatMessage, documentKey: String) {
        if currentDocumentKey == documentKey {
            chatMessages.append(message)
        }

        var payload = loadPayload(for: documentKey)
        payload.chatMessages.append(message)
        save(payload, for: documentKey)
    }

    private func documentKey(for document: PDFDocument) -> String {
        document.fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func storageFileURL(for documentKey: String) -> URL {
        let encodedKey = Data(documentKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")

        return rootDirectoryURL.appendingPathComponent(encodedKey).appendingPathExtension("json")
    }
}