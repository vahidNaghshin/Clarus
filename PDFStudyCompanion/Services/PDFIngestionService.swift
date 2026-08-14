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

        let normalized = normalizeChapterRanges(chapters, pdf: pdf)
        return normalized.isEmpty ? fallbackChapters(for: pdf) : normalized
    }

    // MARK: - Outline walking

    private func chapter(from node: PDFOutline, pdf: PDFKit.PDFDocument) -> Chapter? {
        let title = node.label ?? "Untitled chapter"
        let range = startPageRange(of: node, pdf: pdf)
        let sections = (0..<node.numberOfChildren).compactMap { i -> Section? in
            guard let child = node.child(at: i) else { return nil }
            return section(from: child, pdf: pdf)
        }
        return Chapter(id: UUID(), title: title, sections: sections, pageRange: range)
    }

    private func section(from node: PDFOutline, pdf: PDFKit.PDFDocument) -> Section? {
        let title = node.label ?? "Untitled section"
        let range = startPageRange(of: node, pdf: pdf)
        let anchor = anchor(for: node, pdf: pdf)
        let text = extractText(pages: range, pdf: pdf)
        return Section(id: UUID(), title: title, pageRange: range, startAnchor: anchor, rawText: text)
    }

    private func fallbackChapters(for pdf: PDFKit.PDFDocument) -> [Chapter] {
        guard pdf.pageCount > 0 else { return [] }

        let sections = (0..<pdf.pageCount).map { pageIndex in
            Section(
                id: UUID(),
                title: "Page \(pageIndex + 1)",
                pageRange: pageIndex...pageIndex,
                startAnchor: topAnchor(forPageAt: pageIndex, pdf: pdf),
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

    private func startPageRange(of node: PDFOutline, pdf: PDFKit.PDFDocument) -> ClosedRange<Int> {
        guard let dest = node.destination, let page = dest.page else {
            return 0...0
        }
        let start = pdf.index(for: page)
        return start...start
    }

    private func anchor(for node: PDFOutline, pdf: PDFKit.PDFDocument) -> SectionAnchor? {
        guard let dest = node.destination, let page = dest.page else {
            return nil
        }

        let pageIndex = pdf.index(for: page)
        let point = dest.point
        return SectionAnchor(pageIndex: pageIndex, x: point.x, y: point.y)
    }

    private func topAnchor(forPageAt pageIndex: Int, pdf: PDFKit.PDFDocument) -> SectionAnchor? {
        guard let page = pdf.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        return SectionAnchor(pageIndex: pageIndex, x: bounds.minX, y: bounds.maxY)
    }

    private func normalizeChapterRanges(_ chapters: [Chapter], pdf: PDFKit.PDFDocument) -> [Chapter] {
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { return chapters }

        return chapters.enumerated().map { index, chapter in
            var normalizedChapter = chapter
            normalizedChapter.sections = normalizeSectionRanges(chapter.sections, pdf: pdf)

            let chapterStart = normalizedChapter.sections.first?.pageRange.lowerBound ?? chapter.pageRange.lowerBound
            let chapterEnd: Int
            if index + 1 < chapters.count {
                chapterEnd = max(chapterStart, chapters[index + 1].pageRange.lowerBound - 1)
            } else {
                chapterEnd = pageCount - 1
            }

            normalizedChapter.pageRange = chapterStart...chapterEnd
            return normalizedChapter
        }
    }

    private func normalizeSectionRanges(_ sections: [Section], pdf: PDFKit.PDFDocument) -> [Section] {
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { return sections }

        return sections.enumerated().map { index, section in
            var normalizedSection = section
            let start = section.pageRange.lowerBound
            let end: Int
            if index + 1 < sections.count {
                end = max(start, sections[index + 1].pageRange.lowerBound - 1)
            } else {
                end = pageCount - 1
            }

            normalizedSection.pageRange = start...end
            normalizedSection.rawText = extractText(pages: normalizedSection.pageRange, pdf: pdf)
            return normalizedSection
        }
    }

    private func extractText(pages: ClosedRange<Int>, pdf: PDFKit.PDFDocument) -> String {
        pages.compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
    }
}
