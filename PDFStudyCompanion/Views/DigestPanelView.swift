import SwiftUI

/// Shows the current section's summary and its multiple-choice
/// questions (v1 — no open-response grading yet).
struct DigestPanelView: View {
    let document: PDFDocument?
    let section: Section?
    @ObservedObject var historyStore: InteractionHistoryStore
    @State private var summary: String = ""
    @State private var questions: [MultipleChoiceQuestion] = []
    @State private var errorMessage: String?
    @State private var isSummarizing = false
    @State private var isGeneratingQuestions = false

    var body: some View {
        Group {
            if let section {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(section.title).font(.title3.bold())

                        HStack {
                            Button(isSummarizing ? "Summarizing…" : "Summarize This Section") {
                                summarize(section)
                            }
                            .disabled(isBusy || !hasReadableText(section))

                            Button(isGeneratingQuestions ? "Generating…" : "Give Me Overview Questions") {
                                generateQuestions(for: section)
                            }
                            .disabled(isBusy || !hasReadableText(section))
                        }

                        if !summary.isEmpty || isSummarizing || !hasReadableText(section) {
                            Text(summaryText(for: section))
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }

                        ForEach($questions) { $question in
                            QuestionView(question: $question) {
                                guard let document else { return }
                                historyStore.updateQuestionAnswer(document: document, section: section, question: question)
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
        .onChange(of: section?.id) { _, _ in
            resetContent()
        }
    }

    private var isBusy: Bool {
        isSummarizing || isGeneratingQuestions
    }

    private func summaryText(for section: Section) -> String {
        if !hasReadableText(section) {
            return "This page does not expose selectable text, so there is nothing to summarize yet."
        }

        return summary.isEmpty ? "Generating summary…" : summary
    }

    private func hasReadableText(_ section: Section) -> Bool {
        !section.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetContent() {
        summary = ""
        questions = []
        errorMessage = nil
        isSummarizing = false
        isGeneratingQuestions = false
    }

    private func summarize(_ section: Section) {
        guard hasReadableText(section) else {
            resetContent()
            return
        }

        summary = ""
        errorMessage = nil
        isSummarizing = true

        Task {
            do {
                let llm = BedrockProvider.configured()
                let engine = DigestEngine(llm: llm)
                let generatedSummary = try await engine.summarize(section, style: .prose)

                await MainActor.run {
                    summary = generatedSummary.text
                    if let document {
                        historyStore.addSummary(document: document, section: section, summary: generatedSummary)
                    }
                    isSummarizing = false
                }
            } catch {
                await MainActor.run {
                    summary = ""
                    errorMessage = error.localizedDescription
                    isSummarizing = false
                }
            }
        }
    }

    private func generateQuestions(for section: Section) {
        guard hasReadableText(section) else {
            resetContent()
            return
        }

        questions = []
        errorMessage = nil
        isGeneratingQuestions = true

        Task {
            do {
                let llm = BedrockProvider.configured()
                let engine = DigestEngine(llm: llm)
                let generatedQuestions = try await engine.generateQuestions(for: section, count: 3)

                await MainActor.run {
                    questions = generatedQuestions
                    if let document {
                        historyStore.addQuestions(document: document, section: section, questions: generatedQuestions)
                    }
                    isGeneratingQuestions = false
                }
            } catch {
                await MainActor.run {
                    questions = []
                    errorMessage = error.localizedDescription
                    isGeneratingQuestions = false
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
