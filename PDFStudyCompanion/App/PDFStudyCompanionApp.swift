import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PDFStudyCompanionApp: App {
    @State private var document: PDFDocument?
    @StateObject private var historyStore = InteractionHistoryStore()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document, onOpenPDF: openPDF, historyStore: historyStore)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") {
                    openPDF()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        do {
            document = try PDFIngestionService().ingest(fileURL: fileURL)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could Not Open PDF"
            alert.informativeText = failureMessage(for: error)
            alert.runModal()
        }
    }

    private func failureMessage(for error: Error) -> String {
        switch error {
        case PDFIngestionService.IngestionError.unreadableDocument:
            return "The selected file could not be read as a PDF."
        default:
            return error.localizedDescription
        }
    }
}
