import Foundation

/// Turns raw section text into the reader-facing digest: a summary and
/// a small set of multiple-choice questions. Frequency and style are
/// both meant to be user-configurable from Settings (not wired up yet).
struct DigestEngine {
    var llm: LLMProvider

    func summarize(_ section: Section, style: SummaryStyle) async throws -> Summary {
        let prompt = """
        Summarize the following section in \(style == .bullets ? "bullet points" : "prose"). \
        Keep it concise and focused on the core argument.

        \(section.rawText)
        """
        let text = try await llm.generateText(prompt: prompt, context: [])
        return Summary(id: UUID(), scopeID: section.id, text: text, style: style, generatedAt: Date())
    }

    /// v1 generates multiple-choice only (product decision).
    func generateQuestions(for section: Section, count: Int) async throws -> [MultipleChoiceQuestion] {
        let prompt = """
        Write \(count) multiple-choice comprehension questions for the section below. \
        Return strict JSON: an array of objects with "prompt", "options" (4 strings), \
        and "correctIndex" (0-based). No prose outside the JSON.

        \(section.rawText)
        """
        let raw = try await llm.generateText(prompt: prompt, context: [])
        return try decodeQuestions(raw, sectionID: section.id)
    }

    /// Chapter-end recap plus connections to earlier chapters, using
    /// passages retrieved from EmbeddingStore.
    func summarizeChapter(_ chapter: Chapter, relatedPassages: [String]) async throws -> Summary {
        let prompt = """
        Summarize this chapter, then note any meaningful connections to \
        the passages from earlier chapters below.

        Chapter text:
        \(chapter.sections.map(\.rawText).joined(separator: "\n\n"))

        Related passages from earlier chapters:
        \(relatedPassages.joined(separator: "\n---\n"))
        """
        let text = try await llm.generateText(prompt: prompt, context: [])
        return Summary(id: UUID(), scopeID: chapter.id, text: text, style: .prose, generatedAt: Date())
    }

    private func decodeQuestions(_ json: String, sectionID: UUID) throws -> [MultipleChoiceQuestion] {
        struct Raw: Decodable { let prompt: String; let options: [String]; let correctIndex: Int }
        let items = try JSONDecoder().decode([Raw].self, from: Data(json.utf8))
        return items.map {
            MultipleChoiceQuestion(id: UUID(), sectionID: sectionID, prompt: $0.prompt,
                                    options: $0.options, correctIndex: $0.correctIndex,
                                    userAnswerIndex: nil)
        }
    }
}
