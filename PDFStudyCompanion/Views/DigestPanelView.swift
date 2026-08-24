import SwiftUI

/// Shows the current section's summary and its multiple-choice
/// questions (v1 — no open-response grading yet).
///
/// Responses are cached per section (keyed by `Section.id`) so that
/// scrolling to a different section and back does not lose earlier
/// results. Each response has its own "Refresh" action at the end
/// that re-issues the same query for that section on demand.
struct DigestPanelView: View {
    let document: PDFDocument?
    let section: Section?
    @ObservedObject var historyStore: InteractionHistoryStore
    @State private var summariesBySection: [UUID: String] = [:]
    @State private var questionsBySection: [UUID: [MultipleChoiceQuestion]] = [:]
    @State private var errorsBySection: [UUID: String] = [:]
    @State private var summarizingSectionIDs: Set<UUID> = []
    @State private var generatingQuestionsSectionIDs: Set<UUID> = []

    var body: some View {
        Group {
            if let section {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(section.title).font(.title3.bold())

                        HStack {
                            Button(isSummarizing(section) ? "Summarizing…" : "Summarize This Section") {
                                summarize(section)
                            }
                            .disabled(isBusy(section) || !hasReadableText(section))

                            Button(isGeneratingQuestions(section) ? "Generating…" : "Give Me Overview Questions") {
                                generateQuestions(for: section)
                            }
                            .disabled(isBusy(section) || !hasReadableText(section))
                        }

                        if let summaryText = summaryText(for: section) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(summaryText)
                                    .foregroundStyle(.secondary)

                                if summariesBySection[section.id] != nil {
                                    refreshButton(isLoading: isSummarizing(section)) {
                                        summarize(section)
                                    }
                                }
                            }
                        }

                        if let errorMessage = errorsBySection[section.id] {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }

                        let sectionQuestions = questionsBySection[section.id] ?? []
                        if !sectionQuestions.isEmpty {
                            ForEach(questionsBinding(for: section)) { $question in
                                QuestionView(question: $question) {
                                    guard let document else { return }
                                    historyStore.updateQuestionAnswer(document: document, section: section, question: question)
                                }
                            }

                            refreshButton(isLoading: isGeneratingQuestions(section)) {
                                generateQuestions(for: section)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                HIGEmptyStateView(
                    symbolName: "sparkles.rectangle.stack",
                    symbolSize: 40,
                    symbolWeight: .thin,
                    title: "No Digest Yet",
                    titleSize: 15,
                    titleWeight: .semibold,
                    subtitle: "Select a section from the contents to generate its AI digest.",
                    subtitleSize: 12,
                    subtitleMaxWidth: 160,
                    verticalCenterRatio: 0.45,
                    buttonTitle: nil,
                    buttonAction: nil)
            }
        }
        .onAppear {
            hydrateFromHistory()
        }
        .onChange(of: document?.id) { _, _ in
            hydrateFromHistory()
        }
    }

    /// Rebuilds the in-memory per-section caches from the persisted
    /// interaction history so previously generated summaries and
    /// questions are still available after the PDF is closed and
    /// reopened.
    private func hydrateFromHistory() {
        var summaries: [UUID: String] = [:]
        for record in historyStore.records where record.kind == .summary {
            guard let sectionID = record.sectionID else { continue }
            // Records are sorted most-recent-first, so the first hit per section is the latest summary.
            if summaries[sectionID] == nil {
                summaries[sectionID] = record.body
            }
        }

        var latestGenerationDateBySection: [UUID: Date] = [:]
        for record in historyStore.records where record.kind == .question {
            guard let sectionID = record.sectionID else { continue }
            if let current = latestGenerationDateBySection[sectionID] {
                latestGenerationDateBySection[sectionID] = max(current, record.createdAt)
            } else {
                latestGenerationDateBySection[sectionID] = record.createdAt
            }
        }

        // Only keep the most recently generated batch of questions per section
        // (older, regenerated-over batches are still in history but not shown).
        let generationTolerance: TimeInterval = 5
        var questionsBySectionID: [UUID: [MultipleChoiceQuestion]] = [:]
        for record in historyStore.records where record.kind == .question {
            guard let sectionID = record.sectionID,
                  let latest = latestGenerationDateBySection[sectionID],
                  latest.timeIntervalSince(record.createdAt) <= generationTolerance,
                  let relatedQuestionID = record.relatedQuestionID,
                  let options = record.options,
                  let correctIndex = record.correctAnswerIndex
            else { continue }

            let question = MultipleChoiceQuestion(
                id: relatedQuestionID,
                sectionID: sectionID,
                prompt: record.body,
                options: options,
                correctIndex: correctIndex,
                userAnswerIndex: record.selectedAnswerIndex)

            questionsBySectionID[sectionID, default: []].append(question)
        }

        // historyStore.records is sorted most-recent-first; reverse so
        // questions read back in their original asking order.
        for sectionID in questionsBySectionID.keys {
            questionsBySectionID[sectionID]?.reverse()
        }

        summariesBySection = summaries
        questionsBySection = questionsBySectionID
    }

    @ViewBuilder
    private func refreshButton(isLoading: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(isLoading)
        }
    }

    private func isSummarizing(_ section: Section) -> Bool {
        summarizingSectionIDs.contains(section.id)
    }

    private func isGeneratingQuestions(_ section: Section) -> Bool {
        generatingQuestionsSectionIDs.contains(section.id)
    }

    private func isBusy(_ section: Section) -> Bool {
        isSummarizing(section) || isGeneratingQuestions(section)
    }

    private func questionsBinding(for section: Section) -> Binding<[MultipleChoiceQuestion]> {
        Binding(
            get: { questionsBySection[section.id] ?? [] },
            set: { questionsBySection[section.id] = $0 })
    }

    private func summaryText(for section: Section) -> String? {
        if !hasReadableText(section) {
            return "This page does not expose selectable text, so there is nothing to summarize yet."
        }

        if let existing = summariesBySection[section.id] {
            return existing
        }

        return isSummarizing(section) ? "Generating summary…" : nil
    }

    private func hasReadableText(_ section: Section) -> Bool {
        !section.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func summarize(_ section: Section) {
        guard hasReadableText(section) else { return }

        errorsBySection[section.id] = nil
        summarizingSectionIDs.insert(section.id)

        Task {
            do {
                let llm = BedrockProvider.configured()
                let engine = DigestEngine(llm: llm)
                let generatedSummary = try await engine.summarize(section, style: .prose)

                await MainActor.run {
                    summariesBySection[section.id] = generatedSummary.text
                    if let document {
                        historyStore.addSummary(document: document, section: section, summary: generatedSummary)
                    }
                    summarizingSectionIDs.remove(section.id)
                }
            } catch {
                await MainActor.run {
                    errorsBySection[section.id] = error.localizedDescription
                    summarizingSectionIDs.remove(section.id)
                }
            }
        }
    }

    private func generateQuestions(for section: Section) {
        guard hasReadableText(section) else { return }

        errorsBySection[section.id] = nil
        generatingQuestionsSectionIDs.insert(section.id)

        Task {
            do {
                let llm = BedrockProvider.configured()
                let engine = DigestEngine(llm: llm)
                let generatedQuestions = try await engine.generateQuestions(for: section, count: 10)

                await MainActor.run {
                    questionsBySection[section.id] = generatedQuestions
                    if let document {
                        historyStore.addQuestions(document: document, section: section, questions: generatedQuestions)
                    }
                    generatingQuestionsSectionIDs.remove(section.id)
                }
            } catch {
                await MainActor.run {
                    errorsBySection[section.id] = error.localizedDescription
                    generatingQuestionsSectionIDs.remove(section.id)
                }
            }
        }
    }
}

private struct QuestionView: View {
    @Binding var question: MultipleChoiceQuestion
    let onAnswer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.prompt).fontWeight(.medium)
            ForEach(question.options.indices, id: \.self) { i in
                Button {
                    question.userAnswerIndex = i
                    onAnswer()
                } label: {
                    HStack {
                        Image(systemName: question.userAnswerIndex == i ? "largecircle.fill.circle" : "circle")
                        Text(question.options[i])
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(colorFor(i))
            }
        }
    }

    private func colorFor(_ i: Int) -> Color {
        guard let selected = question.userAnswerIndex else { return .primary }
        if i == question.correctIndex { return .green }
        if i == selected { return .red }
        return .primary
    }
}
