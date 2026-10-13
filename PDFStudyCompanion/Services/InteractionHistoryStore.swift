import Combine
import CryptoKit
import Foundation

@MainActor
final class InteractionHistoryStore: ObservableObject {
    @Published private(set) var records: [InteractionRecord] = []
    @Published private(set) var notes: [Note] = []
    @Published private(set) var highlights: [PersistedHighlight] = []

    private let fileManager: FileManager
    private let rootDirectoryURL: URL
    private var currentDocumentKey: String?

    struct ImportResult {
        let importedRecordCount: Int
        let importedNoteCount: Int
        let importedHighlightCount: Int
    }

    enum TransferError: LocalizedError {
        case invalidExportFormat
        case documentMismatch
        case unableToReadDocumentData

        var errorDescription: String? {
            switch self {
            case .invalidExportFormat:
                return "The selected file is not a valid PDF Study Companion history export."
            case .documentMismatch:
                return "This history export belongs to a different PDF. Open the matching PDF and try again."
            case .unableToReadDocumentData:
                return "The current PDF could not be read well enough to verify the import."
            }
        }
    }

    private struct InteractionHistoryPayload: Codable {
        var records: [InteractionRecord]
        var notes: [Note]
        var highlights: [PersistedHighlight]
    }

    private struct ExportedHistoryPackage: Codable {
        var version: Int
        var exportedAt: Date
        var sourceDocument: ExportedDocument
        var sections: [ExportedSection]
        var payload: InteractionHistoryPayload
    }

    private struct ExportedDocument: Codable {
        var title: String
        var pageCount: Int
        var chapterCount: Int
        var sectionCount: Int
        var sha256: String
    }

    private struct ExportedSection: Codable {
        var id: UUID
        var title: String
        var pageRange: ClosedRange<Int>
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
            return
        }

        let documentKey = self.documentKey(for: document)
        currentDocumentKey = documentKey

        let payload = loadPayload(for: documentKey)
        records = payload.records.sorted { $0.createdAt > $1.createdAt }
        notes = payload.notes.sorted { $0.createdAt > $1.createdAt }
        highlights = payload.highlights.sorted { $0.createdAt > $1.createdAt }
    }

    func suggestedExportFilename(for document: PDFDocument) -> String {
        let baseName = document.title.isEmpty ? "PDFHistory" : document.title
        let sanitized = baseName.replacingOccurrences(of: "/", with: "-")
        return "\(sanitized)-history.json"
    }

    func exportData(for document: PDFDocument) throws -> Data {
        let documentKey = documentKey(for: document)
        let payload = loadPayload(for: documentKey)
        let sections = document.chapters.flatMap(\.sections)
        let package = ExportedHistoryPackage(
            version: 1,
            exportedAt: Date(),
            sourceDocument: ExportedDocument(
                title: document.title,
                pageCount: document.pageCount,
                chapterCount: document.chapters.count,
                sectionCount: sections.count,
                sha256: try documentSHA256(for: document)),
            sections: sections.map {
                ExportedSection(id: $0.id, title: $0.title, pageRange: $0.pageRange)
            },
            payload: payload)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(package)
    }

    func importHistory(from fileURL: URL, into document: PDFDocument) throws -> ImportResult {
        let data = try Data(contentsOf: fileURL)
        return try importHistory(from: data, into: document)
    }

    func importHistory(from data: Data, into document: PDFDocument) throws -> ImportResult {
        let decoder = JSONDecoder()
        guard let package = try? decoder.decode(ExportedHistoryPackage.self, from: data) else {
            throw TransferError.invalidExportFormat
        }

        try validate(package.sourceDocument, matches: document)

        let currentDocumentKey = documentKey(for: document)
        let sectionRemap = makeSectionRemap(exportedSections: package.sections, document: document)
        let reboundPayload = rebind(package.payload, to: document, documentKey: currentDocumentKey, sectionRemap: sectionRemap)

        var existingPayload = loadPayload(for: currentDocumentKey)
        existingPayload.records = mergeUnique(existingPayload.records, reboundPayload.records, id: \.id)
        existingPayload.notes = mergeUnique(existingPayload.notes, reboundPayload.notes, id: \.id)
        existingPayload.highlights = mergeUnique(existingPayload.highlights, reboundPayload.highlights, id: \.id)
        save(existingPayload, for: currentDocumentKey)

        if self.currentDocumentKey == currentDocumentKey {
            records = existingPayload.records.sorted { $0.createdAt > $1.createdAt }
            notes = existingPayload.notes.sorted { $0.createdAt > $1.createdAt }
            highlights = existingPayload.highlights.sorted { $0.createdAt > $1.createdAt }
        }

        return ImportResult(
            importedRecordCount: reboundPayload.records.count,
            importedNoteCount: reboundPayload.notes.count,
            importedHighlightCount: reboundPayload.highlights.count)
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

    func addChatMessage(document: PDFDocument, section: Section, role: ChatMessage.Role, text: String, selectedText: String?) {
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
    }

    private func loadPayload(for documentKey: String) -> InteractionHistoryPayload {
        let fileURL = storageFileURL(for: documentKey)
        guard let data = try? Data(contentsOf: fileURL) else {
            return InteractionHistoryPayload(records: [], notes: [], highlights: [])
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
                highlights: legacyPayload.highlights)
        }

        if let legacyRecords = try? JSONDecoder().decode([InteractionRecord].self, from: data) {
            return InteractionHistoryPayload(records: legacyRecords, notes: [], highlights: [])
        }

        return InteractionHistoryPayload(records: [], notes: [], highlights: [])
    }

    private func save(_ payload: InteractionHistoryPayload, for documentKey: String) {
        let fileURL = storageFileURL(for: documentKey)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func validate(_ exportedDocument: ExportedDocument, matches document: PDFDocument) throws {
        let documentHash = try documentSHA256(for: document)
        guard documentHash == exportedDocument.sha256 else {
            throw TransferError.documentMismatch
        }

        let currentSectionCount = document.chapters.flatMap(\.sections).count
        guard document.pageCount == exportedDocument.pageCount,
              document.chapters.count == exportedDocument.chapterCount,
              currentSectionCount == exportedDocument.sectionCount else {
            throw TransferError.documentMismatch
        }
    }

    private func documentSHA256(for document: PDFDocument) throws -> String {
        guard let data = try? Data(contentsOf: document.fileURL) else {
            throw TransferError.unableToReadDocumentData
        }

        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeSectionRemap(exportedSections: [ExportedSection], document: PDFDocument) -> [UUID: UUID] {
        let currentSections = document.chapters.flatMap(\.sections)
        var remap: [UUID: UUID] = [:]

        for exportedSection in exportedSections {
            if let exactMatch = currentSections.first(where: {
                $0.title == exportedSection.title && $0.pageRange == exportedSection.pageRange
            }) {
                remap[exportedSection.id] = exactMatch.id
                continue
            }

            let titleMatches = currentSections.filter { $0.title == exportedSection.title }
            if titleMatches.count == 1, let onlyMatch = titleMatches.first {
                remap[exportedSection.id] = onlyMatch.id
                continue
            }

            if let pageMatch = currentSections.first(where: {
                $0.pageRange.lowerBound == exportedSection.pageRange.lowerBound
            }) {
                remap[exportedSection.id] = pageMatch.id
            }
        }

        return remap
    }

    private func rebind(
        _ payload: InteractionHistoryPayload,
        to document: PDFDocument,
        documentKey: String,
        sectionRemap: [UUID: UUID]
    ) -> InteractionHistoryPayload {
        let reboundRecords = payload.records.map { record in
            var rebound = record
            rebound.documentKey = documentKey
            if let sectionID = record.sectionID {
                rebound.sectionID = sectionRemap[sectionID] ?? resolveSectionID(
                    title: record.sectionTitle,
                    pageIndex: nil,
                    document: document)
            }
            return rebound
        }

        let reboundNotes = payload.notes.map { note in
            var rebound = note
            rebound.documentID = document.id
            if let sectionID = note.sectionID {
                rebound.sectionID = sectionRemap[sectionID] ?? resolveSectionID(
                    title: note.sectionTitle,
                    pageIndex: note.pageIndex,
                    document: document)
            }
            return rebound
        }

        let reboundHighlights = payload.highlights.map { highlight in
            var rebound = highlight
            rebound.documentID = document.id
            let pageIndex = highlight.segments.first?.pageIndex
            if let sectionID = highlight.sectionID {
                rebound.sectionID = sectionRemap[sectionID] ?? resolveSectionID(
                    title: highlight.sectionTitle,
                    pageIndex: pageIndex,
                    document: document)
            }
            return rebound
        }

        return InteractionHistoryPayload(
            records: reboundRecords,
            notes: reboundNotes,
            highlights: reboundHighlights)
    }

    private func resolveSectionID(title: String?, pageIndex: Int?, document: PDFDocument) -> UUID? {
        let sections = document.chapters.flatMap(\.sections)

        if let title,
           let pageIndex,
           let exactMatch = sections.first(where: {
               $0.title == title && $0.pageRange.contains(pageIndex)
           }) {
            return exactMatch.id
        }

        if let title {
            let titleMatches = sections.filter { $0.title == title }
            if titleMatches.count == 1 {
                return titleMatches.first?.id
            }
        }

        if let pageIndex {
            return sections.first(where: { $0.pageRange.contains(pageIndex) })?.id
        }

        return nil
    }

    private func mergeUnique<Value: Identifiable>(
        _ existing: [Value],
        _ imported: [Value],
        id: KeyPath<Value, Value.ID>
    ) -> [Value] where Value.ID: Hashable {
        var merged = existing
        var seen = Set(existing.map { $0[keyPath: id] })

        for value in imported where !seen.contains(value[keyPath: id]) {
            merged.append(value)
            seen.insert(value[keyPath: id])
        }

        return merged
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