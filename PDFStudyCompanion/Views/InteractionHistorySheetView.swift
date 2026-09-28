import SwiftUI

struct InteractionHistorySheetView: View {
    let document: PDFDocument
    @ObservedObject var historyStore: InteractionHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if historyStore.records.isEmpty {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Summaries, structural reviews, chats, and answered questions for this PDF will appear here."))
                } else {
                    List(historyStore.records) { record in
                        InteractionHistoryRow(record: record)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct InteractionHistoryRow: View {
    let record: InteractionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(record.title, systemImage: iconName)
                    .font(.headline)
                Spacer(minLength: 12)
                Text(record.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(record.sectionTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !record.body.isEmpty {
                Text(record.body)
                    .font(.body)
                    .textSelection(.enabled)
            }

            if record.kind == .question,
               let options = record.options,
               !options.isEmpty
            {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Text(answerLine(for: index, option: option))
                            .foregroundStyle(color(for: index))
                    }
                }
                .font(.footnote)
            }

            if record.kind == .structuralReview,
               let items = record.structuralReviewItems,
               !items.isEmpty
            {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(index + 1). \(item.title)")
                                .font(.subheadline.weight(.semibold))
                            Text(item.hint)
                            ForEach(Array(item.questions.enumerated()), id: \.offset) { questionIndex, question in
                                Text("\(questionIndex + 1). \(question)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }

    private var iconName: String {
        switch record.kind {
        case .summary:
            return "doc.text.magnifyingglass"
        case .chatPrompt:
            return "questionmark.bubble"
        case .chatReply:
            return "bubble.left.and.text.bubble.right"
        case .question:
            return "checklist"
        case .structuralReview:
            return "list.bullet.rectangle.portrait"
        }
    }

    private func answerLine(for index: Int, option: String) -> String {
        var segments: [String] = [option]

        if record.selectedAnswerIndex == index {
            segments.append("your answer")
        }

        if record.correctAnswerIndex == index {
            segments.append("correct")
        }

        guard segments.count > 1 else { return option }
        return "\(option) [\(segments.dropFirst().joined(separator: ", "))]"
    }

    private func color(for index: Int) -> Color {
        if record.correctAnswerIndex == index {
            return .green
        }

        if record.selectedAnswerIndex == index {
            return record.selectedAnswerIndex == record.correctAnswerIndex ? .green : .red
        }

        return .primary
    }
}