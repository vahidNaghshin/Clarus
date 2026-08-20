import SwiftUI

private struct ChatSheetContext: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let section: Section
    let selectedText: String?
    let initialMessages: [ChatMessage]
    let defaultNoteReference: NoteReferenceContext?
    let initialNoteReferences: [UUID: NoteReferenceContext]
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
    @State private var sectionJumpRequest: SectionJumpRequest?
    @State private var selectedText: String?
    @State private var selectedPageIndex: Int?
    @State private var selectedReferenceSegments: [HighlightSegment] = []
    @State private var chatSheetContext: ChatSheetContext?
    @State private var noteDraftContext: NoteDraftContext?
    @State private var noteDraftText = ""
    @State private var focusedHighlight: HighlightFocusRequest?
    @State private var isTestingBedrock = false
    @State private var isTestingVisionModel = false
    @State private var bedrockStatusMessage: String?
    @State private var isBedrockStatusPresented = false
    @State private var isHistoryPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $splitViewVisibility) {
            OutlineSidebarView(document: document, selection: $selectedSection, onSelect: { section in
                sectionJumpRequest = SectionJumpRequest(section: section, token: UUID())
            })
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 360)
        } content: {
            Group {
                if let document {
                    PDFViewerView(
                        document: document,
                        jumpTo: sectionJumpRequest,
                        isHighlightModeEnabled: isHighlightModeEnabled,
                        persistedHighlights: historyStore.highlights,
                        focusedHighlight: focusedHighlight,
                        supportsEquationCapture: BedrockProvider.configured().supportsVision,
                        llmProviderFactory: { BedrockProvider.configured() }
                    ) { event in
                        selectedText = event.selectedText
                        selectedPageIndex = event.pageIndex
                        selectedReferenceSegments = event.referenceSegments

                        guard let pageIndex = event.pageIndex else { return }
                        if let matchedSection = section(for: pageIndex, pagePoint: event.pagePoint, in: document) {
                            selectedSection = matchedSection

                            if event.isCommandHeld, event.selectedText != nil {
                                let noteReference = noteReferenceContext(
                                    section: matchedSection,
                                    selectedText: event.selectedText,
                                    pageIndex: event.pageIndex,
                                    highlightID: nil,
                                    segments: event.referenceSegments)
                                chatSheetContext = ChatSheetContext(
                                    document: document,
                                    section: matchedSection,
                                    selectedText: event.selectedText,
                                    initialMessages: [],
                                    defaultNoteReference: noteReference,
                                    initialNoteReferences: [:])
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
                    } onEquationCaptured: { result in
                        handleEquationCaptureResult(result, in: document)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    HIGEmptyStateView(
                        symbolName: "doc.text.magnifyingglass",
                        symbolSize: 56,
                        symbolWeight: .ultraLight,
                        title: "Open a PDF to Begin",
                        titleSize: 20,
                        titleWeight: .semibold,
                        subtitle: "Click below to choose a PDF file from your Mac.",
                        subtitleSize: 13,
                        subtitleMaxWidth: 240,
                        verticalCenterRatio: 0.5,
                        buttonTitle: "Choose PDF…",
                        buttonAction: onOpenPDF)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button {
                    guard let document, let selectedSection else { return }
                    let noteReference = noteReferenceContext(
                        section: selectedSection,
                        selectedText: selectedText,
                        pageIndex: selectedPageIndex,
                        highlightID: nil,
                        segments: selectedReferenceSegments)
                    chatSheetContext = ChatSheetContext(
                        document: document,
                        section: selectedSection,
                        selectedText: selectedText,
                        initialMessages: [],
                        defaultNoteReference: noteReference,
                        initialNoteReferences: [:])
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
                historyStore: historyStore,
                initialMessages: context.initialMessages,
                defaultNoteReference: context.defaultNoteReference,
                initialNoteReferences: context.initialNoteReferences,
                onAddAssistantMessageToNote: { message, noteReference in
                    addAssistantMessageToNote(
                        message,
                        reference: noteReference,
                        document: context.document,
                        fallbackSection: context.section)
                })
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
        .bedrockStatusBanner()
        .onAppear {
            splitViewVisibility = .all
            historyStore.load(document: document)
        }
        .onReceive(NotificationCenter.default.publisher(for: .runBedrockConnectionTest)) { _ in
            testBedrockConnection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .runVisionModelConnectionTest)) { _ in
            testVisionModelConnection()
        }
        .onChange(of: document?.id) { _, _ in
            splitViewVisibility = .all
            selectedSection = nil
            sectionJumpRequest = nil
            selectedText = nil
            selectedPageIndex = nil
            selectedReferenceSegments = []
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

    private func testVisionModelConnection() {
        isTestingVisionModel = true

        Task {
            let provider = BedrockProvider.configured()

            do {
                let response = try await provider.testVisionConnection()
                await MainActor.run {
                    bedrockStatusMessage = "Visual model connected successfully. Model reply: \(response)"
                    isTestingVisionModel = false
                    isBedrockStatusPresented = true
                }
            } catch {
                await MainActor.run {
                    bedrockStatusMessage = error.localizedDescription
                    isTestingVisionModel = false
                    isBedrockStatusPresented = true
                }
            }
        }
    }

    private func handleEquationCaptureResult(_ result: EquationCaptureResult, in document: PDFDocument) {
        let matchedSection = section(for: result.pageIndex, pagePoint: result.pagePoint, in: document)
            ?? document.chapters.flatMap(\.sections).first
        guard let matchedSection else { return }

        let noteReference = noteReferenceContext(
            section: matchedSection,
            selectedText: nil,
            pageIndex: result.pageIndex,
            highlightID: nil,
            segments: result.referenceSegments)

        selectedSection = matchedSection
        selectedText = nil
        selectedPageIndex = result.pageIndex
        selectedReferenceSegments = result.referenceSegments

        let assistantMessage = ChatMessage(
            id: UUID(),
            documentID: document.id,
            sectionID: matchedSection.id,
            role: .assistant,
            text: result.explanation,
            imageData: result.imageData,
            timestamp: Date())

        historyStore.addChatMessage(
            document: document,
            section: matchedSection,
            role: .assistant,
            text: result.explanation,
            selectedText: "Equation capture")

        if let chatSheetContext,
           chatSheetContext.document.id == document.id,
           chatSheetContext.section.id == matchedSection.id {
            NotificationCenter.default.post(
                name: .equationCaptureDidGenerateMessage,
                object: EquationChatEvent(
                    documentID: document.id,
                    sectionID: matchedSection.id,
                    message: assistantMessage,
                    noteReference: noteReference))
        } else {
            self.chatSheetContext = ChatSheetContext(
                document: document,
                section: matchedSection,
                selectedText: nil,
                initialMessages: [assistantMessage],
                defaultNoteReference: nil,
                initialNoteReferences: [assistantMessage.id: noteReference].compactMapValues { $0 })
        }
    }

    private func noteReferenceContext(
        section: Section?,
        selectedText: String?,
        pageIndex: Int?,
        highlightID: UUID?,
        segments: [HighlightSegment]
    ) -> NoteReferenceContext? {
        guard section != nil || pageIndex != nil || selectedText != nil || !segments.isEmpty else {
            return nil
        }

        return NoteReferenceContext(
            sectionID: section?.id,
            sectionTitle: section?.title,
            selectedText: selectedText,
            pageIndex: pageIndex,
            highlightID: highlightID,
            segments: segments)
    }

    private func addAssistantMessageToNote(
        _ message: ChatMessage,
        reference: NoteReferenceContext?,
        document: PDFDocument,
        fallbackSection: Section
    ) {
        // Guard against duplicate notes when "Add this to note" is pressed
        // more than once for the same chat message (e.g. repeated clicks in
        // the same chat window).
        if let existingNote = historyStore.notes.first(where: { $0.sourceChatMessageID == message.id }) {
            if let highlightID = existingNote.highlightID {
                selectedSection = nil
                focusedHighlight = HighlightFocusRequest(highlightID: highlightID, token: UUID())
            }
            return
        }

        let resolvedSection = reference?.sectionID.flatMap { sectionID in
            document.chapters.flatMap(\.sections).first(where: { $0.id == sectionID })
        } ?? fallbackSection

        var highlightID = reference?.highlightID
        if highlightID == nil,
           let reference,
           !reference.segments.isEmpty {
            let persistedHighlight = historyStore.addHighlight(
                document: document,
                section: resolvedSection,
                selectedText: reference.selectedText,
                segments: reference.segments)
            highlightID = persistedHighlight.id
        }

        historyStore.addNote(
            document: document,
            section: resolvedSection,
            highlightID: highlightID,
            selectedText: reference?.selectedText,
            pageIndex: reference?.pageIndex,
            text: message.text,
            sourceChatMessageID: message.id)

        if let highlightID {
            selectedSection = nil
            focusedHighlight = HighlightFocusRequest(highlightID: highlightID, token: UUID())
        }
    }

    private func openReference(for note: Note) {
        guard let document else { return }

        selectedText = note.selectedText

        if let highlightID = note.highlightID {
            selectedSection = nil
            focusedHighlight = HighlightFocusRequest(highlightID: highlightID, token: UUID())
            if let pageIndex = note.pageIndex {
                selectedPageIndex = pageIndex
            }
            return
        }

        if let sectionID = note.sectionID,
           let matchedSection = document.chapters.flatMap(\.sections).first(where: { $0.id == sectionID }) {
            selectedSection = matchedSection
            sectionJumpRequest = SectionJumpRequest(section: matchedSection, token: UUID())
            return
        }

        if let pageIndex = note.pageIndex,
           let matchedSection = section(for: pageIndex, pagePoint: nil, in: document) {
            selectedSection = matchedSection
            sectionJumpRequest = SectionJumpRequest(section: matchedSection, token: UUID())
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
