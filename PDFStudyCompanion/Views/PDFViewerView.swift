import SwiftUI
import PDFKit

struct PDFSelectionEvent {
    let selectedText: String?
    let pageIndex: Int?
    let pagePoint: CGPoint?
    let referenceSegments: [HighlightSegment]
    let isCommandHeld: Bool
}

struct PDFHighlightNoteRequest {
    let highlightID: UUID?
    let selectedText: String?
    let pageIndex: Int?
}

struct HighlightFocusRequest: Equatable {
    let highlightID: UUID
    let token: UUID
}

final class SelectionAwarePDFView: PDFView {
    var onMouseUp: ((NSEvent) -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?(event)
    }
}

/// Wraps PDFKit's PDFView. Selection changes here are what should feed
/// the "highlight → ask" chat entry point (wiring that up is a TODO —
/// listen for PDFView's selectionChanged notification and pass the
/// selected string up to ContentView).
struct PDFViewerView: NSViewRepresentable {
    let document: PDFDocument
    let jumpTo: Section?
    let isHighlightModeEnabled: Bool
    let persistedHighlights: [PersistedHighlight]
    let focusedHighlight: HighlightFocusRequest?
    let supportsEquationCapture: Bool
    let llmProviderFactory: () -> any LLMProvider
    let onSelectionChange: (PDFSelectionEvent) -> Void
    let onHighlightCreated: (String?, Int?, [HighlightSegment]) -> Void
    let onHighlightNoteRequest: (PDFHighlightNoteRequest) -> Void
    let onHighlightRemoved: (UUID) -> Void
    let onEquationCaptured: (EquationCaptureResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentModel: document,
            supportsEquationCapture: supportsEquationCapture,
            llmProviderFactory: llmProviderFactory,
            onSelectionChange: onSelectionChange,
            onHighlightCreated: onHighlightCreated,
            onHighlightNoteRequest: onHighlightNoteRequest,
            onHighlightRemoved: onHighlightRemoved,
            onEquationCaptured: onEquationCaptured)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = SelectionAwarePDFView()
        view.document = PDFKit.PDFDocument(url: document.fileURL)
        view.autoScales = true
        view.autoresizingMask = [.width, .height]
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = false
        view.backgroundColor = .windowBackgroundColor
        context.coordinator.attach(to: view)
        context.coordinator.installRightClickMonitor(for: view)
        context.coordinator.loadedDocumentID = document.id
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onHighlightCreated = onHighlightCreated
        context.coordinator.onHighlightNoteRequest = onHighlightNoteRequest
        context.coordinator.onHighlightRemoved = onHighlightRemoved
        context.coordinator.onEquationCaptured = onEquationCaptured
        context.coordinator.supportsEquationCapture = supportsEquationCapture
        context.coordinator.llmProviderFactory = llmProviderFactory
        context.coordinator.isHighlightModeEnabled = isHighlightModeEnabled
        context.coordinator.equationCaptureController?.update(
            documentModel: document,
            supportsVision: supportsEquationCapture,
            llmProviderFactory: llmProviderFactory,
            onCaptureResult: onEquationCaptured)

        if context.coordinator.loadedDocumentID != document.id {
            nsView.document = PDFKit.PDFDocument(url: document.fileURL)
            context.coordinator.loadedDocumentID = document.id
            context.coordinator.lastJumpSectionID = nil
        }

        context.coordinator.syncManagedHighlights(in: nsView, persistedHighlights: persistedHighlights)

        if context.coordinator.lastFocusedHighlightToken != focusedHighlight?.token {
            context.coordinator.lastFocusedHighlightToken = focusedHighlight?.token
            if let focusedHighlight {
                context.coordinator.focusHighlight(withID: focusedHighlight.highlightID, in: nsView)
                return
            }
        }

        guard let jumpTo else { return }
        let targetPageIndex = jumpTo.startAnchor?.pageIndex ?? jumpTo.pageRange.lowerBound
        let currentPageIndex = nsView.currentPage.flatMap { currentPage in
            nsView.document?.index(for: currentPage)
        }
        let alreadyShowingTargetSection =
            context.coordinator.lastJumpSectionID == jumpTo.id &&
            currentPageIndex == targetPageIndex

        guard !alreadyShowingTargetSection,
              let page = nsView.document?.page(at: targetPageIndex)
        else { return }

        context.coordinator.lastJumpSectionID = jumpTo.id
        DispatchQueue.main.async {
            if let anchor = jumpTo.startAnchor {
                let destination = PDFDestination(
                    page: page,
                    at: CGPoint(x: anchor.x, y: anchor.y))
                nsView.go(to: destination)
            } else {
                nsView.go(to: page)
            }
        }
    }

    final class Coordinator: NSObject {
        var onSelectionChange: (PDFSelectionEvent) -> Void
        var onHighlightCreated: (String?, Int?, [HighlightSegment]) -> Void
        var onHighlightNoteRequest: (PDFHighlightNoteRequest) -> Void
        var onHighlightRemoved: (UUID) -> Void
        var onEquationCaptured: (EquationCaptureResult) -> Void
        var supportsEquationCapture: Bool
        var llmProviderFactory: () -> any LLMProvider
        var isHighlightModeEnabled = false
        var loadedDocumentID: UUID?
        var lastJumpSectionID: UUID?
        var lastFocusedHighlightToken: UUID?
        var activeFocusedHighlightID: UUID?
        var equationCaptureController: EquationCaptureController?
        private var activeFocusResetToken: UUID?
        private var lastPersistedHighlights: [PersistedHighlight] = []
        weak var pdfView: PDFView?
        var pendingSelectedText: String?
        var pendingPageIndex: Int?
        var pendingPagePoint: CGPoint?
        var pendingReferenceSegments: [HighlightSegment] = []
        private var pendingMenuRequest: PDFHighlightNoteRequest?
        private var rightClickMonitor: Any?
        private static let managedHighlightPrefix = "persisted-highlight:"
        private static let focusRingPrefix = "focus-ring:"
        private static let defaultHighlightColor = NSColor.systemYellow.withAlphaComponent(0.35)
        private static let focusedHighlightColor = NSColor.systemOrange.withAlphaComponent(0.95)
        private static let focusedHighlightDuration: TimeInterval = 3.0

        init(
            documentModel: PDFDocument,
            supportsEquationCapture: Bool,
            llmProviderFactory: @escaping () -> any LLMProvider,
            onSelectionChange: @escaping (PDFSelectionEvent) -> Void,
            onHighlightCreated: @escaping (String?, Int?, [HighlightSegment]) -> Void,
            onHighlightNoteRequest: @escaping (PDFHighlightNoteRequest) -> Void,
            onHighlightRemoved: @escaping (UUID) -> Void,
            onEquationCaptured: @escaping (EquationCaptureResult) -> Void
        ) {
            self.supportsEquationCapture = supportsEquationCapture
            self.llmProviderFactory = llmProviderFactory
            self.onSelectionChange = onSelectionChange
            self.onHighlightCreated = onHighlightCreated
            self.onHighlightNoteRequest = onHighlightNoteRequest
            self.onHighlightRemoved = onHighlightRemoved
            self.onEquationCaptured = onEquationCaptured
            self.equationCaptureController = EquationCaptureController(
                documentModel: documentModel,
                supportsVision: supportsEquationCapture,
                llmProviderFactory: llmProviderFactory,
                onCaptureResult: onEquationCaptured)
        }

        deinit {
            if let rightClickMonitor {
                NSEvent.removeMonitor(rightClickMonitor)
            }

            if let pdfView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewSelectionChanged,
                    object: pdfView)
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewPageChanged,
                    object: pdfView)
            }
        }

        func attach(to pdfView: PDFView) {
            if let existing = self.pdfView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewSelectionChanged,
                    object: existing)
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewPageChanged,
                    object: existing)
            }

            self.pdfView = pdfView
            if let pdfView = pdfView as? SelectionAwarePDFView {
                pdfView.onMouseUp = { [weak self] event in
                    self?.publishPendingSelection(using: event)
                }
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSelectionChanged),
                name: Notification.Name.PDFViewSelectionChanged,
                object: pdfView)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePageChanged),
                name: Notification.Name.PDFViewPageChanged,
                object: pdfView)

            equationCaptureController?.attach(to: pdfView)
        }

        func installRightClickMonitor(for pdfView: PDFView) {
            if let rightClickMonitor {
                NSEvent.removeMonitor(rightClickMonitor)
            }

            rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self, weak pdfView] event in
                guard let self, let pdfView, event.window === pdfView.window else {
                    return event
                }

                let pointInView = pdfView.convert(event.locationInWindow, from: nil)
                guard pdfView.bounds.contains(pointInView) else {
                    return event
                }

                guard let menu = self.contextMenu(at: pointInView) else {
                    return event
                }

                menu.popUp(positioning: nil, at: pointInView, in: pdfView)
                return nil
            }
        }

        @objc private func handleSelectionChanged() {
            guard let pdfView else { return }

            let selectedText = pdfView.currentSelection?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSelectedText = selectedText?.isEmpty == true ? nil : selectedText

            if let selection = pdfView.currentSelection,
               let document = pdfView.document {
                pendingReferenceSegments = highlightSegments(for: selection, in: document)
            } else {
                pendingReferenceSegments = []
            }

            if let page = pdfView.currentSelection?.pages.first {
                pendingPageIndex = pdfView.document?.index(for: page)
                let bounds = pdfView.currentSelection?.bounds(for: page) ?? .zero
                pendingPagePoint = bounds.isEmpty ? nil : CGPoint(x: bounds.midX, y: bounds.midY)
            } else {
                pendingPageIndex = nil
                pendingPagePoint = nil
            }
        }

        @objc private func handlePageChanged() {
            guard let pdfView else { return }

            let visibleLocation = dominantVisibleLocation(in: pdfView)
            pendingPageIndex = visibleLocation?.pageIndex
            pendingPagePoint = visibleLocation?.pointOnPage

            onSelectionChange(
                PDFSelectionEvent(
                    selectedText: pendingSelectedText,
                    pageIndex: pendingPageIndex,
                    pagePoint: pendingPagePoint,
                    referenceSegments: pendingReferenceSegments,
                    isCommandHeld: false))
        }

        private func publishPendingSelection(using event: NSEvent) {
            if let pdfView {
                let pointInView = pdfView.convert(event.locationInWindow, from: nil)
                if let clickedPage = pdfView.page(for: pointInView, nearest: true) {
                    pendingPageIndex = pdfView.document?.index(for: clickedPage)
                    pendingPagePoint = pdfView.convert(pointInView, to: clickedPage)
                } else if let visibleLocation = dominantVisibleLocation(in: pdfView) {
                    pendingPageIndex = visibleLocation.pageIndex
                    pendingPagePoint = visibleLocation.pointOnPage
                }
            }

            let isCommandHeld = event.modifierFlags.contains(.command)

            guard pendingSelectedText != nil else {
                onSelectionChange(
                    PDFSelectionEvent(
                        selectedText: nil,
                        pageIndex: pendingPageIndex,
                        pagePoint: pendingPagePoint,
                        referenceSegments: [],
                        isCommandHeld: isCommandHeld))
                return
            }

            if isHighlightModeEnabled && !isCommandHeld {
                addHighlightForCurrentSelection()
            }

            onSelectionChange(
                PDFSelectionEvent(
                    selectedText: pendingSelectedText,
                    pageIndex: pendingPageIndex,
                    pagePoint: pendingPagePoint,
                    referenceSegments: pendingReferenceSegments,
                    isCommandHeld: isCommandHeld))
        }

        private func dominantVisibleLocation(in pdfView: PDFView) -> (pageIndex: Int, pointOnPage: CGPoint)? {
            let visibleRect = pdfView.visibleRect
            let visibleMidPoint = NSPoint(x: visibleRect.midX, y: visibleRect.midY)

            if let centerPage = pdfView.page(for: visibleMidPoint, nearest: true) {
                guard let pageIndex = pdfView.document?.index(for: centerPage) else { return nil }
                return (pageIndex, pdfView.convert(visibleMidPoint, to: centerPage))
            }

            let visiblePages = pdfView.visiblePages
            if !visiblePages.isEmpty {
                let fallbackPage = visiblePages[visiblePages.count / 2]
                guard let pageIndex = pdfView.document?.index(for: fallbackPage) else { return nil }
                let bounds = fallbackPage.bounds(for: .mediaBox)
                return (pageIndex, CGPoint(x: bounds.midX, y: bounds.midY))
            }

            if let currentPage = pdfView.currentPage,
               let pageIndex = pdfView.document?.index(for: currentPage) {
                let bounds = currentPage.bounds(for: .mediaBox)
                return (pageIndex, CGPoint(x: bounds.midX, y: bounds.midY))
            }

            return nil
        }

        private func addHighlightForCurrentSelection() {
            guard let pdfView,
                  let selection = pdfView.currentSelection,
                  let document = pdfView.document
            else { return }

            let segments = highlightSegments(for: selection, in: document)

            guard !segments.isEmpty else { return }

            onHighlightCreated(pendingSelectedText, segments.first?.pageIndex, segments)
        }

        private func highlightSegments(for selection: PDFSelection, in document: PDFKit.PDFDocument) -> [HighlightSegment] {
            var segments: [HighlightSegment] = []

            for lineSelection in selection.selectionsByLine() {
                for page in lineSelection.pages {
                    let bounds = lineSelection.bounds(for: page)
                    guard !bounds.isEmpty else { continue }
                    let pageIndex = document.index(for: page)
                    segments.append(HighlightSegment(pageIndex: pageIndex, bounds: bounds))
                }
            }

            if selection.pages.isEmpty {
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex) else { continue }
                    let bounds = selection.bounds(for: page)
                    guard !bounds.isEmpty else { continue }
                    segments.append(HighlightSegment(pageIndex: pageIndex, bounds: bounds))
                }
            }

            return segments
        }

        private func noteRequestForContextMenu(at pointInView: NSPoint) -> PDFHighlightNoteRequest? {
            guard let pdfView,
                  let page = pdfView.page(for: pointInView, nearest: true)
            else { return nil }

            let pointOnPage = pdfView.convert(pointInView, to: page)
            let pageIndex = pdfView.document?.index(for: page)
            let annotation = highlightAnnotation(near: pointOnPage, on: page)
            let fallbackSelection = pdfView.currentSelection?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedText = annotation?.contents ?? (fallbackSelection?.isEmpty == true ? nil : fallbackSelection)

            return PDFHighlightNoteRequest(
                highlightID: annotation.flatMap(highlightID(for:)),
                selectedText: selectedText,
                pageIndex: pageIndex)
        }

        /// Builds our own context menu rather than delegating to `PDFView.menu(for:)`.
        /// PDFKit's built-in menu construction is not documented as safe to call
        /// directly from a custom event monitor and has been observed to crash
        /// when the click lands on a highlight annotation, so we avoid it entirely
        /// and provide the handful of actions users actually need ourselves.
        private func contextMenu(at pointInView: NSPoint) -> NSMenu? {
            guard let pdfView else { return nil }

            let noteRequest = noteRequestForContextMenu(at: pointInView)
            let queryText = noteRequest?.selectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSelection = !(queryText?.isEmpty ?? true)
            let menu = NSMenu(title: "PDF")

            if hasSelection {
                pendingMenuRequest = noteRequest

                let copyItem = NSMenuItem(title: "Copy", action: #selector(handleCopyMenuItem(_:)), keyEquivalent: "")
                copyItem.target = self
                menu.addItem(copyItem)

                let lookUpItem = NSMenuItem(
                    title: "Look Up Word",
                    action: #selector(handleLookUpMenuItem(_:)),
                    keyEquivalent: "")
                lookUpItem.target = self
                menu.addItem(lookUpItem)

                let googleItem = NSMenuItem(
                    title: "Search Google",
                    action: #selector(handleSearchGoogleMenuItem(_:)),
                    keyEquivalent: "")
                googleItem.target = self
                menu.addItem(googleItem)
            }

                if let noteRequest,
                    noteRequest.highlightID != nil || (isHighlightModeEnabled && noteRequest.selectedText != nil) {
                pendingMenuRequest = noteRequest

                let addToNotesItem = NSMenuItem(
                    title: "Add to Notes",
                    action: #selector(handleAddToNotesMenuItem(_:)),
                    keyEquivalent: "")
                addToNotesItem.target = self
                menu.addItem(addToNotesItem)

                if let highlightID = noteRequest.highlightID {
                    let removeItem = NSMenuItem(
                        title: "Remove Highlight",
                        action: #selector(handleRemoveHighlightMenuItem(_:)),
                        keyEquivalent: "")
                    removeItem.target = self
                    removeItem.representedObject = highlightID
                    menu.addItem(removeItem)
                }
            }

            return menu.items.isEmpty ? nil : menu
        }

        @objc private func handleCopyMenuItem(_ sender: NSMenuItem) {
            guard let text = pendingMenuRequest?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func handleAddToNotesMenuItem(_ sender: NSMenuItem) {
            guard let request = pendingMenuRequest else { return }
            onHighlightNoteRequest(request)
            pendingMenuRequest = nil
        }

        @objc private func handleLookUpMenuItem(_ sender: NSMenuItem) {
            guard let text = pendingMenuRequest?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let url = URL(string: "dict://\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
            else { return }

            NSWorkspace.shared.open(url)
        }

        @objc private func handleSearchGoogleMenuItem(_ sender: NSMenuItem) {
            guard let text = pendingMenuRequest?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let url = URL(string: "https://www.google.com/search?q=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
            else { return }

            NSWorkspace.shared.open(url)
        }

        @objc private func handleRemoveHighlightMenuItem(_ sender: NSMenuItem) {
            guard let highlightID = sender.representedObject as? UUID else { return }
            onHighlightRemoved(highlightID)
        }

        /// Finds the highlight annotation under (or near) a click point.
        /// We deliberately search by our own `userName` tag with a generous
        /// tolerance instead of relying on `PDFPage.annotation(at:)` or a
        /// strict `.type` check — PDFKit's own hit-testing for markup-style
        /// annotations (highlight, underline, etc.) is documented to depend
        /// on `quadrilateralPoints`, which we intentionally don't set, so it
        /// can silently miss annotations we create from plain bounds.
        private func highlightAnnotation(near pointOnPage: NSPoint, on page: PDFPage) -> PDFAnnotation? {
            let managed = page.annotations.filter { ($0.userName ?? "").hasPrefix(Self.managedHighlightPrefix) }

            if let exact = managed.first(where: { $0.bounds.contains(pointOnPage) }) {
                return exact
            }

            return managed.first { $0.bounds.insetBy(dx: -12, dy: -8).contains(pointOnPage) }
        }

        private func highlightID(for annotation: PDFAnnotation) -> UUID? {
            guard let userName = annotation.userName,
                  userName.hasPrefix(Self.managedHighlightPrefix)
            else { return nil }

            return UUID(uuidString: String(userName.dropFirst(Self.managedHighlightPrefix.count)))
        }

        func syncManagedHighlights(in pdfView: PDFView, persistedHighlights: [PersistedHighlight]) {
            guard let document = pdfView.document else { return }
            lastPersistedHighlights = persistedHighlights

            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let managed = page.annotations.filter {
                    let userName = $0.userName ?? ""
                    return userName.hasPrefix(Self.managedHighlightPrefix) || userName.hasPrefix(Self.focusRingPrefix)
                }
                for annotation in managed {
                    page.removeAnnotation(annotation)
                }
            }

            for highlight in persistedHighlights {
                let isFocused = highlight.id == activeFocusedHighlightID

                for segment in highlight.segments {
                    guard let page = document.page(at: segment.pageIndex) else { continue }
                    let annotation = PDFAnnotation(bounds: segment.bounds, forType: .highlight, withProperties: nil)
                    annotation.color = isFocused ? Self.focusedHighlightColor : Self.defaultHighlightColor
                    annotation.contents = highlight.selectedText
                    annotation.userName = Self.managedHighlightPrefix + highlight.id.uuidString
                    page.addAnnotation(annotation)

                    if isFocused {
                        let ring = PDFAnnotation(
                            bounds: segment.bounds.insetBy(dx: -6, dy: -4),
                            forType: .square,
                            withProperties: nil)
                        ring.color = NSColor.systemRed.withAlphaComponent(0.95)
                        ring.interiorColor = .clear
                        ring.border = {
                            let border = PDFBorder()
                            border.lineWidth = 3
                            return border
                        }()
                        ring.userName = Self.focusRingPrefix + highlight.id.uuidString
                        page.addAnnotation(ring)
                    }
                }
            }

            pdfView.needsDisplay = true
        }

        func focusHighlight(withID highlightID: UUID, in pdfView: PDFView) {
            guard let document = pdfView.document else { return }
            activeFocusedHighlightID = highlightID
            let targetSegments = lastPersistedHighlights.first(where: { $0.id == highlightID })?.segments ?? []

            var targetPage: PDFPage?
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let hasMatch = page.annotations.contains {
                    $0.userName == Self.managedHighlightPrefix + highlightID.uuidString
                }
                if hasMatch {
                    targetPage = page
                    break
                }
            }

            // Rebuild immediately so the focused color and ring appear without
            // waiting for the next unrelated SwiftUI update.
            syncManagedHighlights(in: pdfView, persistedHighlights: lastPersistedHighlights)

            if let targetSegment = targetSegments.first,
               let targetPage = document.page(at: targetSegment.pageIndex) {
                let destination = PDFDestination(
                    page: targetPage,
                    at: CGPoint(x: targetSegment.bounds.midX, y: targetSegment.bounds.maxY))
                pdfView.go(to: destination)
            } else if let targetPage {
                pdfView.go(to: targetPage)
            }

            pdfView.needsDisplay = true

            let resetToken = UUID()
            activeFocusResetToken = resetToken

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusedHighlightDuration) { [weak self, weak pdfView] in
                guard let self, let pdfView, self.activeFocusResetToken == resetToken else { return }
                self.activeFocusedHighlightID = nil
                self.syncManagedHighlights(in: pdfView, persistedHighlights: self.lastPersistedHighlights)
            }
        }
    }
}
