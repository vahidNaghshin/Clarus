import PDFKit
import Foundation
import CryptoKit

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
        let documentKey = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let chapters = chapters(for: pdf, documentKey: documentKey)

        return PDFDocument(
            id: deterministicID(from: [documentKey, "document"]),
            title: fileURL.deletingPathExtension().lastPathComponent,
            fileURL: fileURL,
            pageCount: pdf.pageCount,
            chapters: chapters,
            importedAt: Date()
        )
    }

    /// Derives a stable UUID from content that stays the same every time
    /// the same PDF is re-ingested (file path plus hierarchical position
    /// and title), instead of a random `UUID()`. This lets persisted
    /// history (summaries, questions, notes, highlights) keyed by
    /// section/chapter/document ID keep matching up after the app or
    /// document is reopened.
    private func deterministicID(from components: [String]) -> UUID {
        let joined = components.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                            bytes[4], bytes[5], bytes[6], bytes[7],
                            bytes[8], bytes[9], bytes[10], bytes[11],
                            bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func chapters(for pdf: PDFKit.PDFDocument, documentKey: String) -> [Chapter] {
        guard let outline = pdf.outlineRoot, outline.numberOfChildren > 0 else {
            return fallbackChapters(for: pdf, documentKey: documentKey)
        }

        let chapters = (0..<outline.numberOfChildren).compactMap { i -> Chapter? in
            guard let node = outline.child(at: i) else { return nil }
            return chapter(from: node, pdf: pdf, documentKey: documentKey, chapterIndex: i)
        }

        let normalized = normalizeChapterRanges(chapters, pdf: pdf)
        return normalized.isEmpty ? fallbackChapters(for: pdf, documentKey: documentKey) : normalized
    }

    // MARK: - Outline walking

    private func chapter(from node: PDFOutline, pdf: PDFKit.PDFDocument, documentKey: String, chapterIndex: Int) -> Chapter? {
        let title = node.label ?? "Untitled chapter"
        let range = startPageRange(of: node, pdf: pdf)
        let sections: [Section]

        // Some PDFs (notably technical papers) place sections directly at
        // the top level with no subsection children. Treat those leaf nodes
        // as actual sections so the sidebar and Study panel still work.
        if node.numberOfChildren == 0 {
            guard let singleSection = section(from: node, pdf: pdf, documentKey: documentKey, chapterIndex: chapterIndex, sectionIndex: 0) else { return nil }
            sections = [singleSection]
        } else {
            var collected: [Section] = []

            // Keep the parent node as its own section entry so text that
            // appears between a section heading and its first subsection
            // is not dropped during ingestion.
            if let parentSection = section(from: node, pdf: pdf, documentKey: documentKey, chapterIndex: chapterIndex, sectionIndex: 0) {
                collected.append(parentSection)
            }

            collected.append(contentsOf: (0..<node.numberOfChildren).compactMap { i -> Section? in
                guard let child = node.child(at: i) else { return nil }
                return section(from: child, pdf: pdf, documentKey: documentKey, chapterIndex: chapterIndex, sectionIndex: i + 1)
            })

            sections = collected
        }

        let chapterID = deterministicID(from: [documentKey, "chapter", String(chapterIndex), title])
        return Chapter(id: chapterID, title: title, sections: sections, pageRange: range)
    }

    private func section(from node: PDFOutline, pdf: PDFKit.PDFDocument, documentKey: String, chapterIndex: Int, sectionIndex: Int) -> Section? {
        let title = node.label ?? "Untitled section"
        let range = startPageRange(of: node, pdf: pdf)
        let anchor = anchor(for: node, pdf: pdf)
        let text = extractText(pages: range, pdf: pdf)
        let sectionID = deterministicID(from: [documentKey, "section", String(chapterIndex), String(sectionIndex), title])
        return Section(id: sectionID, title: title, pageRange: range, startAnchor: anchor, rawText: text)
    }

    private func fallbackChapters(for pdf: PDFKit.PDFDocument, documentKey: String) -> [Chapter] {
        guard pdf.pageCount > 0 else { return [] }

        let sections = (0..<pdf.pageCount).map { pageIndex in
            Section(
                id: deterministicID(from: [documentKey, "fallback-section", String(pageIndex)]),
                title: "Page \(pageIndex + 1)",
                pageRange: pageIndex...pageIndex,
                startAnchor: topAnchor(forPageAt: pageIndex, pdf: pdf),
                rawText: extractText(pages: pageIndex...pageIndex, pdf: pdf))
        }

        return [
            Chapter(
                id: deterministicID(from: [documentKey, "fallback-chapter"]),
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
