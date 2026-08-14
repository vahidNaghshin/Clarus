import Foundation

/// Represents an imported PDF and its parsed structure.
/// v1 relies on the PDF's embedded outline (table of contents) to build
/// this — no OCR, so PDFs without embedded text/outline aren't supported yet.
struct PDFDocument: Identifiable, Codable {
    let id: UUID
    var title: String
    var fileURL: URL
    var pageCount: Int
    var chapters: [Chapter]
    var importedAt: Date
}

/// A chapter is the top level of the document outline.
struct Chapter: Identifiable, Codable {
    let id: UUID
    var title: String
    var sections: [Section]
    var pageRange: ClosedRange<Int>
}

/// A section is the unit the digest engine summarizes and quizzes on.
struct Section: Identifiable, Codable {
    let id: UUID
    var title: String
    var pageRange: ClosedRange<Int>
    var rawText: String
}
