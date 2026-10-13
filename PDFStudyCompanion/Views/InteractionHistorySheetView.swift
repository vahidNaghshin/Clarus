import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InteractionHistorySheetView: View {
    let document: PDFDocument
    @ObservedObject var historyStore: InteractionHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var transferAlertMessage = ""
    @State private var isTransferAlertPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        importHistory()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        exportHistory()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!hasAnyHistory)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

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
        .alert("History Transfer", isPresented: $isTransferAlertPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(transferAlertMessage)
        }
    }

    private var hasAnyHistory: Bool {
        !historyStore.records.isEmpty || !historyStore.notes.isEmpty || !historyStore.highlights.isEmpty
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.title = "Export History"
        panel.message = "Save this PDF's study history to a portable JSON file."
        panel.nameFieldStringValue = historyStore.suggestedExportFilename(for: document)
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            let data = try historyStore.exportData(for: document)
            try data.write(to: destinationURL, options: .atomic)
            presentTransferMessage("Exported history for \(document.title) to \(destinationURL.lastPathComponent).")
        } catch {
            presentTransferMessage(error.localizedDescription)
        }
    }

    private func importHistory() {
        let panel = NSOpenPanel()
        panel.title = "Import History"
        panel.message = "Choose a history export for the currently open PDF."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            let result = try historyStore.importHistory(from: sourceURL, into: document)
            presentTransferMessage(
                "Imported \(result.importedRecordCount) history items, \(result.importedNoteCount) notes, and \(result.importedHighlightCount) highlights into \(document.title).")
        } catch {
            presentTransferMessage(error.localizedDescription)
        }
    }

    private func presentTransferMessage(_ message: String) {
        transferAlertMessage = message
        isTransferAlertPresented = true
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