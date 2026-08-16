import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let runBedrockConnectionTest = Notification.Name("runBedrockConnectionTest")
    static let runVisionModelConnectionTest = Notification.Name("runVisionModelConnectionTest")
}

private let initialWindowWidth: CGFloat = 1440
private let initialWindowHeight: CGFloat = 1620

private struct InitialWindowSizeAccessor: NSViewRepresentable {
    let size: NSSize

    func makeNSView(context: Context) -> InitialWindowSizeView {
        let view = InitialWindowSizeView()
        view.size = size
        return view
    }

    func updateNSView(_ nsView: InitialWindowSizeView, context: Context) {
        nsView.size = size
    }
}

private final class InitialWindowSizeView: NSView {
    var size: NSSize = .zero
    private var didApplySize = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window, !didApplySize else { return }
        window.setContentSize(size)
        didApplySize = true
    }
}

@main
struct PDFStudyCompanionApp: App {
    @State private var document: PDFDocument?
    @StateObject private var historyStore = InteractionHistoryStore()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document, onOpenPDF: openPDF, historyStore: historyStore)
                .background(
                    InitialWindowSizeAccessor(
                        size: NSSize(width: initialWindowWidth, height: initialWindowHeight)))
        }
        .defaultSize(width: initialWindowWidth, height: initialWindowHeight)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") {
                    openPDF()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("Debug") {
                Button("Test Bedrock") {
                    NotificationCenter.default.post(name: .runBedrockConnectionTest, object: nil)
                }

                Button("Test Visual Model") {
                    NotificationCenter.default.post(name: .runVisionModelConnectionTest, object: nil)
                }
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
