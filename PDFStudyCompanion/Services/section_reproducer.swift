import Foundation

/// Builds a lightweight story map for a section, then asks the text
/// model for a Socratic review that guides reproduction rather than
/// revealing the answer directly.
struct SectionReproducer {
    var llm: LLMProvider

    func generateReview(for section: Section) async throws -> StructuralReviewGeneration {
        let storyMap = parse(section)
        let prompt = buildPrompt(for: section, storyMap: storyMap)
        let raw = try await llm.generateText(prompt: prompt, context: [section.rawText])
        do {
            let items = try decodeItems(from: raw)

            return StructuralReviewGeneration(
                review: StructuralReview(
                    id: UUID(),
                    scopeID: section.id,
                    items: items,
                    generatedAt: Date()),
                rawResponse: raw)
        } catch {
            throw StructuralReviewError.invalidResponse(
                message: error.localizedDescription,
                rawResponse: raw)
        }
    }

    private func parse(_ section: Section) -> StoryMap {
        let paragraphs = splitParagraphs(in: section.rawText)
        let sentences = paragraphs.flatMap(extractSentences)

        return StoryMap(
            sectionTitle: section.title,
            concepts: extractConcepts(from: section.rawText),
            equations: extractEquations(from: section.rawText),
            arguments: paragraphs.map(firstSentence(in:)).compactMap { $0 }.prefix(6).map { $0 },
            transitions: extractTransitions(from: sentences),
            narrativeArc: paragraphs.enumerated().compactMap { index, paragraph in
                guard let sentence = firstSentence(in: paragraph) else { return nil }
                return "Step \(index + 1): \(sentence)"
            }.prefix(6).map { $0 })
    }

    private func buildPrompt(for section: Section, storyMap: StoryMap) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let storyMapJSON = (try? encoder.encode(storyMap)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sourceText = section.rawText

        return """
        SYSTEM PROMPT
        You are section_reproducer, a Socratic learning assistant specializing in
        deliberate practice and deep reconstruction of technical material.

        IDENTITY & MISSION
        Your sole purpose is to help the learner reconstruct a section of text entirely
        from memory, not recognize it, not summarize it, but reproduce it: every concept,
        every equation derivation step, every logical transition, every motivation.

        You operate at Learning Quality Level 3-5:
          Level 3: Learner can apply concepts to unfamiliar problems
          Level 4: Learner can teach it accurately to someone else
          Level 5: Learner can generate novel extensions
        Never produce output that keeps the learner at Level 0-2 (recognition/recall only).

        ABSOLUTE CONSTRAINTS
          - Never state the answer, conclusion, or result of any concept or equation.
          - Never reproduce more than 4 consecutive words from the source text verbatim.
          - Never confirm or deny whether a learner's attempt is correct.
          - Never use phrases that imply the answer, such as "this is because...", "the key insight is...", "remember that...", or "note that...".
          - Never finish a reasoning chain; always stop one step before the conclusion.
          - Never give the right-hand side of any equation the learner must derive.
          - Never summarize a concept in a way that could be passively memorized.

        HINT CONSTRUCTION RULES
        Every hint must satisfy all of the following:
          - Be a question, a partial scaffold, or a sequencing cue, never a statement of fact.
          - Target exactly one element of the narrative: one concept, one step, or one transition.
          - Be self-contained; the learner must not need the original text to understand the hint.
          - Create productive struggle: hard enough to require effort, scoped enough to be actionable.
          - For equations, provide only the left-hand side or the conceptual goal, never the derivation.
          - For transitions, name the two endpoints but never state the connection.
          - For motivations, ask why it was introduced here; never explain why.
          - For conclusions, ask what the result allows the learner to do; never state that outcome.

        QUESTION QUALITY STANDARDS
        Each Socratic question must be one of these types:
          - GENERATIVE: "Can you derive / construct / define [X] from first principles?"
          - DIAGNOSTIC: "What would break if [component] were removed or changed?"
          - CONNECTIVE: "What is the logical bridge between [A] and [B]?"
          - PREDICTIVE: "Before reading the next step, what do you expect the author to do, and why?"
          - CONTRASTIVE: "How does [X] differ from [Y], and why does that difference matter here?"
          - MOTIVATIONAL: "Why did the author need to introduce [X] at this exact point in the argument?"

        Avoid weak question patterns:
          - "What is X?"
          - "Can you recall X?"
          - "Do you remember...?"
          - Yes/no questions

        USER PROMPT
        TASK
        Build a structured reproduction scaffold for the section titled "\(section.title)".
        The learner has read this section and must now reproduce it entirely from memory.
        Your output will be their only guide; they do not have access to the original text.

        INPUTS PROVIDED
          Story map (structured narrative extracted from the section):
          \(storyMapJSON)

          Source text (the original section; use this to ensure full coverage and
          accurate granularity, but never quote it directly in your output):
          \(sourceText)

        NARRATIVE UNDERSTANDING REQUIREMENT
        Before generating output, internally identify:
          1. START POINT: What prior knowledge does the section assume?
          2. END POINT: What should the learner be able to do, derive, or explain after mastery?
          3. CRISIS POINTS: Where does the section introduce a problem that forces a new concept?
          4. STORY ARC: Setup -> Complication -> Resolution; map each element to this arc.

        Your checkpoints must follow this narrative arc in order.
        Each checkpoint must feel like a necessary step in a story, not an isolated quiz question.

        OUTPUT SPECIFICATION
        Return strict JSON only. No markdown, no explanation, no text outside the JSON.

        Return an array of 5 to 8 objects. Each object must have exactly these fields:
        {
          "checkpoint_id": integer starting at 1,
          "narrative_position": one of ["setup", "motivation", "complication", "concept_introduction", "derivation_step", "transition", "resolution", "extension"],
          "title": "short label describing what this checkpoint covers in the story arc",
          "prerequisite_checkpoint_ids": [list of checkpoint_ids this builds upon],
          "hint": "a single concise cue that orients the learner to this part of the section without stating content",
          "questions": [
            {
              "question_text": "the Socratic question",
              "question_type": one of ["generative", "diagnostic", "connective", "predictive", "contrastive", "motivational"],
              "targets": "the specific concept, equation, or argument this question probes"
            }
          ],
          "reproduction_goal": "one sentence describing what a correct reproduction of this element looks like, phrased as an outcome and not as content",
          "common_misconception": "one misconception learners typically have at this point, phrased as a question the learner might wrongly answer"
        }

        COVERAGE REQUIREMENTS
          - Every equation derivation step in the source text must map to at least one checkpoint.
          - Every conceptual transition must map to at least one checkpoint.
          - Every motivation (why this was introduced) must be probed by at least one question.
          - The first checkpoint must address the section's starting assumption or problem setup.
          - The last checkpoint must address the section's conclusion or what mastery enables.
          - No checkpoint may be skipped due to difficulty.

        QUESTION COUNT
          - Minimum 2, maximum 4 questions per checkpoint.
          - Use more questions for derivation_step and complication checkpoints.
          - Use fewer questions for transition and setup checkpoints.
          - At least one question per checkpoint must be of type "generative" or "diagnostic".

        SELF-CHECK BEFORE OUTPUTTING
        Before returning your response, verify:
          - No hint or question contains the answer to what it is asking.
          - Every equation referenced has only its left-hand side or goal stated, never the result.
          - The checkpoints follow the narrative arc of the section in order.
          - A learner with only this output could reconstruct the full section in detail.
          - No two questions in the same checkpoint ask the same thing in different words.
          - The JSON is valid and matches the schema exactly.
        """

    }

    private func decodeItems(from raw: String) throws -> [StructuralReviewItem] {
        let items: [StructuralReviewItem]

        do {
            let payload = try extractJSONPayload(from: raw)
            items = try normalizeItems(from: payload)
        } catch {
            let salvagedItems = salvageItems(from: raw)
            guard !salvagedItems.isEmpty else {
                throw error
            }
            items = salvagedItems
        }

        guard !items.isEmpty else {
            throw LLMProviderError.invalidResponse("Structural review response did not include any usable checkpoints.")
        }

        return items
    }

    private func extractJSONPayload(from raw: String) throws -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let direct = tryParseJSON(trimmed) {
            return direct
        }

        if let fenced = unwrapCodeFence(from: trimmed),
           let parsed = tryParseJSON(fenced) {
            return parsed
        }

        if let snippet = firstBalancedJSONSnippet(in: trimmed),
           let parsed = tryParseJSON(snippet) {
            return parsed
        }

        throw LLMProviderError.invalidResponse("Structural review response was not valid JSON.")
    }

    private func tryParseJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func unwrapCodeFence(from text: String) -> String? {
        guard text.hasPrefix("```") else { return nil }

        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return nil }

        let body = lines.dropFirst().dropLast().joined(separator: "\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstBalancedJSONSnippet(in text: String) -> String? {
        let characters = Array(text)
        guard let startIndex = characters.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }

        let opener = characters[startIndex]
        let closer: Character = opener == "[" ? "]" : "}"
        var depth = 0
        var isInsideString = false
        var isEscaping = false

        for index in startIndex..<characters.count {
            let character = characters[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
                continue
            }

            if character == opener {
                depth += 1
            } else if character == closer {
                depth -= 1
                if depth == 0 {
                    return String(characters[startIndex...index])
                }
            }
        }

        return nil
    }

    private func normalizeItems(from payload: Any) throws -> [StructuralReviewItem] {
        guard let itemPayloads = extractCheckpointList(from: payload) else {
            if payload is [String: Any] || payload is [Any] {
                throw LLMProviderError.invalidResponse("Structural review response JSON did not contain a checkpoint list.")
            }
            throw LLMProviderError.invalidResponse("Structural review response JSON had an unsupported top-level format.")
        }

        return itemPayloads.enumerated().compactMap { index, item in
            let title = stringValue(in: item, keys: ["title", "label", "name"])
                ?? "Checkpoint \(index + 1)"
            let hint = stringValue(in: item, keys: ["hint", "cue", "reproduction_goal", "common_misconception"])
            let questions = normalizeQuestions(from: item["questions"])

            guard let hint, !questions.isEmpty else { return nil }

            return StructuralReviewItem(
                id: UUID(),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                hint: hint.trimmingCharacters(in: .whitespacesAndNewlines),
                questions: questions)
        }
    }

    private func normalizeQuestions(from value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if let objects = value as? [[String: Any]] {
            return objects.compactMap { object in
                stringValue(in: object, keys: ["question_text", "text", "question", "prompt"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        }

        if let single = value as? String {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        return []
    }

    private func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }

        return nil
    }

    private func extractCheckpointList(from payload: Any) -> [[String: Any]]? {
        if let dictionary = payload as? [String: Any] {
            if looksLikeCheckpoint(dictionary) {
                return [dictionary]
            }

            let preferredKeys = [
                "checkpoints",
                "checkpoint_list",
                "checkpointList",
                "items",
                "structural_review",
                "review",
                "response",
                "result",
                "data"
            ]

            for key in preferredKeys {
                if let value = dictionary[key], let nested = extractCheckpointList(from: value) {
                    return nested
                }
            }

            for value in dictionary.values {
                if let nested = extractCheckpointList(from: value) {
                    return nested
                }
            }

            return nil
        }

        if let objects = payload as? [[String: Any]], objects.contains(where: looksLikeCheckpoint) {
            return objects
        }

        if let array = payload as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            if objects.count == array.count, objects.contains(where: looksLikeCheckpoint) {
                return objects
            }

            for value in array {
                if let nested = extractCheckpointList(from: value) {
                    return nested
                }
            }
        }

        return nil
    }

    private func salvageItems(from raw: String) -> [StructuralReviewItem] {
        let candidate = unwrapCodeFence(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)

        var seen = Set<String>()
        var payloads: [[String: Any]] = []

        for snippet in extractJSONObjectSnippets(in: candidate) {
            guard let parsed = tryParseJSON(snippet) else { continue }

            if let checkpoints = extractCheckpointList(from: parsed) {
                for checkpoint in checkpoints {
                    let fingerprint = checkpointFingerprint(checkpoint)
                    if seen.insert(fingerprint).inserted {
                        payloads.append(checkpoint)
                    }
                }
                continue
            }

            if let checkpoint = parsed as? [String: Any], looksLikeCheckpoint(checkpoint) {
                let fingerprint = checkpointFingerprint(checkpoint)
                if seen.insert(fingerprint).inserted {
                    payloads.append(checkpoint)
                }
            }
        }

        return payloads.enumerated().compactMap { index, item in
            let title = stringValue(in: item, keys: ["title", "label", "name"])
                ?? "Checkpoint \(index + 1)"
            let hint = stringValue(in: item, keys: ["hint", "cue", "reproduction_goal", "common_misconception"])
            let questions = normalizeQuestions(from: item["questions"])

            guard let hint, !questions.isEmpty else { return nil }

            return StructuralReviewItem(
                id: UUID(),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                hint: hint.trimmingCharacters(in: .whitespacesAndNewlines),
                questions: questions)
        }
    }

    private func extractJSONObjectSnippets(in text: String) -> [String] {
        let characters = Array(text)
        var snippets: [String] = []
        var objectStartIndex: Int?
        var objectDepth = 0
        var isInsideString = false
        var isEscaping = false

        for index in characters.indices {
            let character = characters[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
                continue
            }

            if character == "{" {
                if objectDepth == 0 {
                    objectStartIndex = index
                }
                objectDepth += 1
                continue
            }

            if character == "}" {
                guard objectDepth > 0 else { continue }
                objectDepth -= 1
                if objectDepth == 0, let startIndex = objectStartIndex {
                    snippets.append(String(characters[startIndex...index]))
                    objectStartIndex = nil
                }
            }
        }

        return snippets
    }

    private func checkpointFingerprint(_ checkpoint: [String: Any]) -> String {
        let title = stringValue(in: checkpoint, keys: ["title", "label", "name"]) ?? ""
        let hint = stringValue(in: checkpoint, keys: ["hint", "cue", "reproduction_goal", "common_misconception"]) ?? ""
        let questions = normalizeQuestions(from: checkpoint["questions"]).joined(separator: "\u{241E}")
        return [title, hint, questions].joined(separator: "\u{241F}")
    }

    private func looksLikeCheckpoint(_ object: [String: Any]) -> Bool {
        let hasTitle = stringValue(in: object, keys: ["title", "label", "name"]) != nil
        let hasHint = stringValue(in: object, keys: ["hint", "cue", "reproduction_goal", "common_misconception"]) != nil
        let hasQuestions = !normalizeQuestions(from: object["questions"]).isEmpty
        return hasQuestions && (hasTitle || hasHint)
    }

    private func splitParagraphs(in text: String) -> [String] {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func extractSentences(from paragraph: String) -> [String] {
        paragraph
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func firstSentence(in paragraph: String) -> String? {
        extractSentences(from: paragraph).first
    }

    private func extractConcepts(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "about", "after", "also", "among", "because", "before", "being", "between", "could", "during",
            "each", "from", "have", "into", "more", "most", "other", "should", "their", "there",
            "these", "those", "through", "using", "what", "when", "where", "which", "while", "with",
            "would", "this", "that", "than", "then", "them", "they", "were", "been", "does", "such"
        ]

        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }
        var counts: [String: Int] = [:]

        for token in tokens {
            let word = String(token)
            guard word.count >= 4, !stopWords.contains(word) else { continue }
            counts[word, default: 0] += 1
        }

        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(8)
            .map(\.key)
    }

    private func extractEquations(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty && (
                    $0.contains("=") ||
                    $0.contains("$") ||
                    $0.contains("\\(") ||
                    $0.contains("\\[") ||
                    ($0.range(of: #"[0-9A-Za-z][\^\+\-\*/][0-9A-Za-z]"#, options: .regularExpression) != nil)
                )
            }
            .prefix(4)
            .map { $0 }
    }

    private func extractTransitions(from sentences: [String]) -> [String] {
        let markers = ["however", "therefore", "thus", "next", "then", "finally", "because", "so", "in contrast", "for example"]

        return sentences.filter { sentence in
            let lowered = sentence.lowercased()
            return markers.contains(where: { lowered.contains($0) })
        }
        .prefix(6)
        .map { $0 }
    }
}

struct StructuralReviewGeneration {
    var review: StructuralReview
    var rawResponse: String
}

enum StructuralReviewError: LocalizedError {
    case invalidResponse(message: String, rawResponse: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message, _):
            return message
        }
    }

    var rawResponse: String {
        switch self {
        case .invalidResponse(_, let rawResponse):
            return rawResponse
        }
    }
}

private struct StoryMap: Encodable {
    var sectionTitle: String
    var concepts: [String]
    var equations: [String]
    var arguments: [String]
    var transitions: [String]
    var narrativeArc: [String]
}

typealias section_reproducer = SectionReproducer