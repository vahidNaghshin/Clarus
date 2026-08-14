import SwiftUI

private struct ChatSheetContext: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let section: Section
    let selectedText: String?
}

private struct NoteDraftContext: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let section: Section?
    let highlightID: UUID?
    let selectedText: String?
    let pageIndex: Int?
}

/// The three-pane layout we settled on: outline sidebar, PDF viewer,
/// digest panel. Chat opens as a trailing sheet rather than a new
/// window, so it always feels attached to the current reading spot.
struct ContentView: View {
    let document: PDFDocument?
    let onOpenPDF: () -> Void
    @ObservedObject var historyStore: InteractionHistoryStore
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var isHighlightModeEnabled = false
    @State private var selectedSection: Section?
    @State private var selectedText: String?
    @State private var chatSheetContext: ChatSheetContext?
    @State private var noteDraftContext: NoteDraftContext?
    @State private var noteDraftText = ""
    @State private var focusedHighlight: HighlightFocusRequest?
    @State private var isTestingBedrock = false
    @State private var bedrockStatusMessage: String?
    @State private var isBedrockStatusPresented = false
    @State private var isHistoryPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            OutlineSidebarView(document: document, selection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 360)
        } content: {
            Group {
                if let document {
                    PDFViewerView(
                        document: document,
                        jumpTo: selectedSection,
                        isHighlightModeEnabled: isHighlightModeEnabled,
                        persistedHighlights: historyStore.highlights,
                        focusedHighlight: focusedHighlight
                    ) { event in
                        selectedText = event.selectedText

                        guard let pageIndex = event.pageIndex else { return }
                        if let matchedSection = section(for: pageIndex, pagePoint: event.pagePoint, in: document) {
                            selectedSection = matchedSection

                            if event.isCommandHeld, event.selectedText != nil {
                                chatSheetContext = ChatSheetContext(
                                    document: document,
                                    section: matchedSection,
                                    selectedText: event.selectedText)
                            }
                        }
                    } onHighlightCreated: { selectedText, pageIndex, segments in
                        let matchedSection = pageIndex.flatMap { section(for: $0, pagePoint: nil, in: document) }
                        _ = historyStore.addHighlight(
                            document: document,
                            section: matchedSection,
                            selectedText: selectedText,
                            segments: segments)
                    } onHighlightNoteRequest: { request in
                        let matchedSection = request.pageIndex.flatMap { section(for: $0, pagePoint: nil, in: document) }
                        if let matchedSection {
                            selectedSection = matchedSection
                        }
                        noteDraftText = ""
                        noteDraftContext = NoteDraftContext(
                            document: document,
                            section: matchedSection,
                            highlightID: request.highlightID,
                            selectedText: request.selectedText,
                            pageIndex: request.pageIndex)
                    } onHighlightRemoved: { highlightID in
                        historyStore.removeHighlight(document: document, highlightID: highlightID)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    ContentUnavailableView(
                        "Open a PDF to begin",
                        systemImage: "doc.text",
                        description: Text("Click here to choose a PDF file."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpenPDF)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .navigationSplitViewColumnWidth(min: 560, ideal: 840, max: 1600)
        } detail: {
            RightSidebarView(
                document: document,
                section: selectedSection,
                historyStore: historyStore,
                onSelectNote: openReference(for:))
            .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isHighlightModeEnabled.toggle()
                } label: {
                    Label("Highlight", systemImage: isHighlightModeEnabled ? "highlighter" : "pencil.tip")
                }
                .help("Toggle highlight mode. When enabled, drag to highlight text. Hold Command while dragging to open chat instead.")
                .disabled(document == nil)
            }

            ToolbarItem {
                Button {
                    isHistoryPresented = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .disabled(document == nil)
            }

            ToolbarItem {
                Button(isTestingBedrock ? "Testing…" : "Test Bedrock") {
                    testBedrockConnection()
                }
                .disabled(isTestingBedrock)
            }

            ToolbarItem {
                Button {
                    guard let document, let selectedSection else { return }
                    chatSheetContext = ChatSheetContext(
                        document: document,
                        section: selectedSection,
                        selectedText: selectedText)
                } label: {
                    Label("Ask", systemImage: "bubble.left.and.bubble.right")
                }
                .disabled(selectedSection == nil)
            }
        }
        .sheet(item: $chatSheetContext) { context in
            ChatPanelView(
                document: context.document,
                section: context.section,
                selectedText: context.selectedText,
                historyStore: historyStore)
        }
        .sheet(item: $noteDraftContext) { context in
            NoteComposerSheet(
                selectedText: context.selectedText,
                referenceTitle: referenceTitle(for: context),
                noteText: $noteDraftText,
                onCancel: {
                    noteDraftContext = nil
                    noteDraftText = ""
                },
                onSave: {
                    let trimmedNote = noteDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedNote.isEmpty else { return }
                    historyStore.addNote(
                        document: context.document,
                        section: context.section,
                        highlightID: context.highlightID,
                        selectedText: context.selectedText,
                        pageIndex: context.pageIndex,
                        text: trimmedNote)
                    noteDraftContext = nil
                    noteDraftText = ""
                })
        }
        .sheet(isPresented: $isHistoryPresented) {
            if let document {
                InteractionHistorySheetView(document: document, historyStore: historyStore)
            }
        }
        .alert("Bedrock Status", isPresented: $isBedrockStatusPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(bedrockStatusMessage ?? "No status available.")
        }
        .onAppear {
            splitViewVisibility = .all
            historyStore.load(document: document)
        }
        .onChange(of: document?.id) { _, _ in
            splitViewVisibility = .all
            selectedSection = nil
            selectedText = nil
            chatSheetContext = nil
            noteDraftContext = nil
            noteDraftText = ""
            focusedHighlight = nil
            historyStore.load(document: document)
        }
    }

    private func section(for pageIndex: Int, pagePoint: CGPoint?, in document: PDFDocument) -> Section? {
        let sections = document.chapters
            .flatMap(\.sections)
            .sorted {
                let lhsPage = $0.startAnchor?.pageIndex ?? $0.pageRange.lowerBound
                let rhsPage = $1.startAnchor?.pageIndex ?? $1.pageRange.lowerBound

                if lhsPage == rhsPage {
                    let lhsY = $0.startAnchor?.y ?? Double.greatestFiniteMagnitude
                    let rhsY = $1.startAnchor?.y ?? Double.greatestFiniteMagnitude
                    if lhsY == rhsY {
                        return $0.pageRange.upperBound < $1.pageRange.upperBound
                    }
                    return lhsY > rhsY
                }
                return lhsPage < rhsPage
            }

        if let pagePoint,
           let anchoredMatch = sections.last(where: { section in
               let startPage = section.startAnchor?.pageIndex ?? section.pageRange.lowerBound
               if startPage < pageIndex { return true }
               if startPage > pageIndex { return false }
               let startY = section.startAnchor?.y ?? Double.greatestFiniteMagnitude
               return startY >= pagePoint.y
           }) {
            return anchoredMatch
        }

        if let exactMatch = sections.first(where: { $0.pageRange.contains(pageIndex) }) {
            return exactMatch
        }

        return sections.last(where: { ($0.startAnchor?.pageIndex ?? $0.pageRange.lowerBound) <= pageIndex })
    }

    private func testBedrockConnection() {
        isTestingBedrock = true

        Task {
            let provider = BedrockProvider.configured()

            do {
                let response = try await provider.testConnection()
                await MainActor.run {
                    bedrockStatusMessage = "Connected successfully. Model reply: \(response)"
                    isTestingBedrock = false
                    isBedrockStatusPresented = true
                }
            } catch {
                await MainActor.run {
                    bedrockStatusMessage = error.localizedDescription
                    isTestingBedrock = false
                    isBedrockStatusPresented = true
                }
            }
        }
    }

    private func openReference(for note: Note) {
        guard let document else { return }

        selectedText = note.selectedText

        if let highlightID = note.highlightID {
            focusedHighlight = HighlightFocusRequest(highlightID: highlightID, token: UUID())
        }

        if let sectionID = note.sectionID,
           let matchedSection = document.chapters.flatMap(\.sections).first(where: { $0.id == sectionID }) {
            selectedSection = matchedSection
            return
        }

        if let pageIndex = note.pageIndex,
           let matchedSection = section(for: pageIndex, pagePoint: nil, in: document) {
            selectedSection = matchedSection
        }
    }

    private func referenceTitle(for context: NoteDraftContext) -> String {
        if let section = context.section {
            return section.title
        }

        if let pageIndex = context.pageIndex {
            return "Page \(pageIndex + 1)"
        }

        return "Highlighted passage"
    }
}
