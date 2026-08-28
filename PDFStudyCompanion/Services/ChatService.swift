import Foundation

/// Assembles context the way we designed: selection (if any) + the
/// current section, always; whole-document retrieval only when the
/// question seems to reach beyond the current section.
struct ChatService {
    var llm: LLMProvider
    var embeddingStore: EmbeddingStore?
    var documentID: String

    /// `history` is the chat window's prior messages (oldest first), so
    /// the model sees earlier turns of this same conversation instead of
    /// treating every send as a brand-new, memory-less request.
    /// `extraContext` and `images` carry one-off attachments (e.g. a
    /// cropped equation image and its nearby-text context) that should
    /// go out with this particular prompt.
    func send(
        _ userText: String,
        selection: String?,
        currentSection: Section,
        history: [ChatMessage] = [],
        extraContext: [String] = [],
        images: [LLMImageInput] = []
    ) async throws -> String {
        var context: [String] = [currentSection.rawText]
        if let selection { context.insert(selection, at: 0) }
        context.append(contentsOf: extraContext)

        if shouldRetrieve(for: userText),
           let embeddingStore,
           let queryEmbedding = try? await embed(userText),
           let related = try? embeddingStore.nearest(to: queryEmbedding, documentID: documentID)
        {
            context.append(contentsOf: related)
        }

        return try await llm.generateText(prompt: userText, context: context, images: images, history: history)
    }

    /// Cheap heuristic for v1: retrieve only when the question references
    /// the document broadly ("earlier", "chapter", "compare", etc). A
    /// small classifier call can replace this later.
    private func shouldRetrieve(for text: String) -> Bool {
        let triggers = ["earlier", "chapter", "compare", "previous", "before", "elsewhere"]
        let lowered = text.lowercased()
        return triggers.contains { lowered.contains($0) }
    }

    private func embed(_ text: String) async throws -> [Float] {
        // TODO: call the embedding model (e.g. Bedrock Titan Embeddings).
        throw LLMProviderError.notImplemented("embedding call")
    }
}
