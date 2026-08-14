import PDFKit
import Foundation

/// Opens a PDF and turns it into the structured Chapter/Section model
/// the rest of the app works with. When a PDF does not provide an
/// outline, the service synthesizes a simple page-based structure so the
/// document still opens and can be explored.
struct PDFIngestionService {

    enum IngestionError: Error {
        case unreadableDocument
    }

    func ingest(fileURL: URL) throws -> PDFDocument {
        guard let pdf = PDFKit.PDFDocument(url: fileURL) else {
            throw IngestionError.unreadableDocument
        }
        let chapters = chapters(for: pdf)

        return PDFDocument(
            id: UUID(),
            title: fileURL.deletingPathExtension().lastPathComponent,
            fileURL: fileURL,
            pageCount: pdf.pageCount,
            chapters: chapters,
            importedAt: Date()
        )
    }

    private func chapters(for pdf: PDFKit.PDFDocument) -> [Chapter] {
        guard let outline = pdf.outlineRoot, outline.numberOfChildren > 0 else {
            return fallbackChapters(for: pdf)
        }

        let chapters = (0..<outline.numberOfChildren).compactMap { i -> Chapter? in
            guard let node = outline.child(at: i) else { return nil }
            return chapter(from: node, pdf: pdf)
        }

        return chapters.isEmpty ? fallbackChapters(for: pdf) : chapters
    }

    // MARK: - Outline walking

    private func chapter(from node: PDFOutline, pdf: PDFKit.PDFDocument) -> Chapter? {
        let title = node.label ?? "Untitled chapter"
        let range = pageRange(of: node, pdf: pdf)
        let sections = (0..<node.numberOfChildren).compactMap { i -> Section? in
            guard let child = node.child(at: i) else { return nil }
            return section(from: child, pdf: pdf)
        }
        return Chapter(id: UUID(), title: title, sections: sections, pageRange: range)
    }

    private func section(from node: PDFOutline, pdf: PDFKit.PDFDocument) -> Section? {
        let title = node.label ?? "Untitled section"
        let range = pageRange(of: node, pdf: pdf)
        let text = extractText(pages: range, pdf: pdf)
        return Section(id: UUID(), title: title, pageRange: range, rawText: text)
    }

    private func fallbackChapters(for pdf: PDFKit.PDFDocument) -> [Chapter] {
        guard pdf.pageCount > 0 else { return [] }

        let sections = (0..<pdf.pageCount).map { pageIndex in
            Section(
                id: UUID(),
                title: "Page \(pageIndex + 1)",
                pageRange: pageIndex...pageIndex,
                rawText: extractText(pages: pageIndex...pageIndex, pdf: pdf))
        }

        return [
            Chapter(
                id: UUID(),
                title: "Document",
                sections: sections,
                pageRange: 0...(pdf.pageCount - 1))
        ]
    }

    /// Simplified: uses just the node's own start page. A fuller
    /// implementation looks ahead to the next sibling's start page (or
    /// the parent's end) to compute where this section actually ends.
    private func pageRange(of node: PDFOutline, pdf: PDFKit.PDFDocument) -> ClosedRange<Int> {
        guard let dest = node.destination, let page = dest.page else {
            return 0...0
        }
        let start = pdf.index(for: page)
        return start...start
    }

    private func extractText(pages: ClosedRange<Int>, pdf: PDFKit.PDFDocument) -> String {
        pages.compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
    }
}
