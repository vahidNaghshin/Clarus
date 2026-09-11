import Foundation

/// LLM-generated summary for a section or chapter.
struct Summary: Identifiable, Codable {
    let id: UUID
    var scopeID: UUID          // a Section.id or Chapter.id
    var text: String
    var style: SummaryStyle
    var generatedAt: Date
}

enum SummaryStyle: String, Codable {
    case bullets
    case prose
}

/// v1 ships multiple-choice only, chosen for implementation simplicity.
/// Open-response grading is a possible v2 addition.
struct MultipleChoiceQuestion: Identifiable, Codable {
    let id: UUID
    var sectionID: UUID
    var prompt: String
    var options: [String]
    var correctIndex: Int
    var userAnswerIndex: Int?
}

struct StructuralReview: Identifiable, Codable {
    let id: UUID
    var scopeID: UUID
    var items: [StructuralReviewItem]
    var generatedAt: Date
}

struct StructuralReviewItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var hint: String
    var questions: [String]
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var documentID: UUID
    var sectionID: UUID?
    var role: Role
    var text: String
    var imageData: Data?
    var timestamp: Date

    enum Role: String, Codable { case user, assistant }
}

struct NoteReferenceContext {
    var sectionID: UUID?
    var sectionTitle: String?
    var selectedText: String?
    var pageIndex: Int?
    var highlightID: UUID?
    var segments: [HighlightSegment]
}

/// A saved chat answer or highlight note. Feeds the (future) export
/// pipeline to Markdown / flashcards.
struct Note: Identifiable, Codable {
    let id: UUID
    var documentID: UUID
    var sectionID: UUID?
    var sectionTitle: String?
    var highlightID: UUID?
    var selectedText: String?
    var pageIndex: Int?
    var text: String
    var sourceChatMessageID: UUID?
    var createdAt: Date
}

struct HighlightSegment: Codable, Hashable {
    var pageIndex: Int
    var bounds: CGRect
}

struct PersistedHighlight: Identifiable, Codable {
    let id: UUID
    var documentID: UUID
    var sectionID: UUID?
    var sectionTitle: String?
    var selectedText: String?
    var segments: [HighlightSegment]
    var createdAt: Date
}

enum InteractionKind: String, Codable {
    case summary
    case chatPrompt
    case chatReply
    case question
    case structuralReview
}

struct InteractionRecord: Identifiable, Codable {
    let id: UUID
    var documentKey: String
    var sectionID: UUID?
    var sectionTitle: String
    var kind: InteractionKind
    var title: String
    var body: String
    var createdAt: Date
    var relatedQuestionID: UUID?
    var options: [String]?
    var selectedAnswerIndex: Int?
    var correctAnswerIndex: Int?
    var structuralReviewItems: [StructuralReviewItem]?
}
