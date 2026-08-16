import AppKit
import Foundation
import PDFKit
import os

enum EquationCaptureState: Equatable {
    case idle
    case armed
    case dragging(rect: CGRect)
    case processing(ProcessingStep)
    case failed(String)
}

enum ProcessingStep: String, Equatable {
    case locating
    case rendering
    case assemblingContext
    case requesting
}

struct EquationCaptureResult {
    var pageIndex: Int
    var pagePoint: CGPoint
    var referenceSegments: [HighlightSegment]
    var imageData: Data
    var explanation: String
}

struct EquationExplanationPayload {
    var imageData: Data
    var explanation: String
}

final class EquationCaptureController: NSObject {
    private static let logger = Logger(subsystem: "PDFStudyCompanion", category: "EquationCapture")
    private static let minimumDragSize = CGSize(width: 10, height: 10)
    private static let maximumImageEdge: CGFloat = 1800
    private static let renderScale: CGFloat = 4

    private weak var pdfView: PDFView?
    private weak var overlayView: EquationCaptureOverlayView?
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var isPointerInside = false
    private var dragStartPoint: CGPoint?

    private(set) var state: EquationCaptureState = .idle {
        didSet {
            Self.logger.debug("state \(String(describing: oldValue)) -> \(String(describing: self.state))")
            overlayView?.needsDisplay = true
            updateCursor()
        }
    }

    var documentModel: PDFDocument
    var llmProviderFactory: () -> any LLMProvider
    var onCaptureResult: (EquationCaptureResult) -> Void
    var supportsVision: Bool

    init(
        documentModel: PDFDocument,
        supportsVision: Bool,
        llmProviderFactory: @escaping () -> any LLMProvider,
        onCaptureResult: @escaping (EquationCaptureResult) -> Void
    ) {
        self.documentModel = documentModel
        self.supportsVision = supportsVision
        self.llmProviderFactory = llmProviderFactory
        self.onCaptureResult = onCaptureResult
    }

    deinit {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView

        if overlayView == nil {
            let overlayView = EquationCaptureOverlayView(controller: self)
            overlayView.frame = pdfView.bounds
            overlayView.autoresizingMask = [.width, .height]
            pdfView.addSubview(overlayView)
            self.overlayView = overlayView
        }

        installMonitors()
        updateCursor()
    }

    func update(
        documentModel: PDFDocument,
        supportsVision: Bool,
        llmProviderFactory: @escaping () -> any LLMProvider,
        onCaptureResult: @escaping (EquationCaptureResult) -> Void
    ) {
        self.documentModel = documentModel
        self.supportsVision = supportsVision
        self.llmProviderFactory = llmProviderFactory
        self.onCaptureResult = onCaptureResult

        if !supportsVision, case .armed = state {
            transition(to: .idle)
        }
    }

    var shouldInterceptMouse: Bool {
        switch state {
        case .armed, .dragging:
            return true
        default:
            return false
        }
    }

    func handleMouseEntered() {
        isPointerInside = true
        updateArmingFromCurrentModifiers()
    }

    func handleMouseExited() {
        isPointerInside = false
        if case .armed = state {
            transition(to: .idle)
        }
    }

    func handleMouseDown(at point: CGPoint) {
        guard case .armed = state else { return }
        dragStartPoint = point
        transition(to: .dragging(rect: CGRect(origin: point, size: .zero)))
    }

    func handleMouseDragged(to point: CGPoint) {
        guard let dragStartPoint,
              case .dragging = state
        else { return }

        transition(to: .dragging(rect: CGRect(x: dragStartPoint.x, y: dragStartPoint.y, width: point.x - dragStartPoint.x, height: point.y - dragStartPoint.y).standardized))
    }

    func handleMouseUp(at point: CGPoint) {
        guard let dragStartPoint,
              case .dragging = state,
              let pdfView
        else { return }

        self.dragStartPoint = nil
        let rect = CGRect(x: dragStartPoint.x, y: dragStartPoint.y, width: point.x - dragStartPoint.x, height: point.y - dragStartPoint.y).standardized

        guard rect.width >= Self.minimumDragSize.width,
              rect.height >= Self.minimumDragSize.height
        else {
            transition(to: .idle)
            return
        }

        transition(to: .processing(.locating))

        guard let located = locateSelection(in: rect, pdfView: pdfView) else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.explainEquation(page: located.page, rect: located.rectOnPage)
                self.onCaptureResult(
                    EquationCaptureResult(
                        pageIndex: located.pageIndex,
                        pagePoint: CGPoint(x: located.rectOnPage.midX, y: located.rectOnPage.midY),
                        referenceSegments: [HighlightSegment(pageIndex: located.pageIndex, bounds: located.rectOnPage)],
                        imageData: payload.imageData,
                        explanation: payload.explanation))
                self.transition(to: .idle)
            } catch {
                self.failInline(error.localizedDescription)
            }
        }
    }

    func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        if case .dragging = state {
            return event
        }

        updateArmingFromModifiers(event.modifierFlags)
        return event
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53 else { return event }

        switch state {
        case .armed, .dragging:
            dragStartPoint = nil
            transition(to: .idle)
            return nil
        default:
            return event
        }
    }

    func explainEquation(page: PDFPage, rect: CGRect) async throws -> EquationExplanationPayload {
        transition(to: .processing(.rendering))
        let imageData = try renderCaptureImage(page: page, rect: rect)

        transition(to: .processing(.assemblingContext))
        let pageIndex = documentModel.fileURL.isFileURL ? page.document?.index(for: page) ?? 0 : 0
        let context = assembleContext(page: page, rect: rect, pageIndex: pageIndex)

        transition(to: .processing(.requesting))
        let provider = llmProviderFactory()
        guard provider.supportsVision else {
            throw LLMProviderError.notImplemented("The current backend does not support image explanations.")
        }

        let prompt = """
        Explain the captured equation. Describe what the equation represents, what each important symbol means, and how the surrounding text says it is derived or used. If the surrounding text does not provide a derivation, say so clearly instead of guessing.
        """

        let explanation = try await provider.generateText(
            prompt: prompt,
            context: context,
            images: [LLMImageInput(data: imageData, mimeType: "image/png")])

        return EquationExplanationPayload(imageData: imageData, explanation: explanation)
    }

    func drawOverlay(in dirtyRect: NSRect) {
        switch state {
        case .dragging(let rect):
            NSColor.systemBlue.withAlphaComponent(0.16).setFill()
            rect.fill()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            NSColor.systemBlue.setStroke()
            path.stroke()
        case .processing(let step):
            drawStatusBadge("Explaining equation: \(step.rawValue)…", in: dirtyRect, color: .systemBlue)
        case .failed(let message):
            drawStatusBadge(message, in: dirtyRect, color: .systemRed)
        default:
            break
        }
    }

    private func installMonitors() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event) ?? event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    private func updateArmingFromCurrentModifiers() {
        updateArmingFromModifiers(NSEvent.modifierFlags)
    }

    private func updateArmingFromModifiers(_ modifierFlags: NSEvent.ModifierFlags) {
        guard supportsVision, isPointerInside else {
            if case .armed = state {
                transition(to: .idle)
            }
            return
        }

        let activeFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isChordHeld = activeFlags.contains(.shift) && activeFlags.contains(.command)

        switch state {
        case .idle where isChordHeld:
            transition(to: .armed)
        case .armed where !isChordHeld:
            transition(to: .idle)
        default:
            break
        }
    }

    private func locateSelection(in rectInView: CGRect, pdfView: PDFView) -> (page: PDFPage, pageIndex: Int, rectOnPage: CGRect)? {
        let cornerPoints = [
            CGPoint(x: rectInView.minX, y: rectInView.minY),
            CGPoint(x: rectInView.maxX, y: rectInView.minY),
            CGPoint(x: rectInView.minX, y: rectInView.maxY),
            CGPoint(x: rectInView.maxX, y: rectInView.maxY)
        ]

        let pages = cornerPoints.compactMap { pdfView.page(for: $0, nearest: true) }
        guard pages.count == 4,
              let firstPage = pages.first,
              pages.allSatisfy({ $0 === firstPage })
        else {
            failInline("Selection must stay on one page.")
            return nil
        }

        let rectOnPage = pdfView.convert(rectInView, to: firstPage).standardized
        guard let pageIndex = pdfView.document?.index(for: firstPage) else {
            failInline("Could not locate the selected page.")
            return nil
        }

        return (firstPage, pageIndex, rectOnPage)
    }

    private func renderCaptureImage(page: PDFPage, rect: CGRect) throws -> Data {
        let pageBounds = page.bounds(for: .mediaBox)
        let cropRect = rect.standardized.intersection(pageBounds)

        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else {
            throw LLMProviderError.invalidResponse("The selected equation region is empty.")
        }

        let limitedScale = min(Self.renderScale, Self.maximumImageEdge / max(cropRect.width, cropRect.height))
        let pixelWidth = max(Int((cropRect.width * limitedScale).rounded(.up)), 1)
        let pixelHeight = max(Int((cropRect.height * limitedScale).rounded(.up)), 1)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw LLMProviderError.invalidResponse("Failed to create an image for the selected equation.")
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: limitedScale, y: limitedScale)
        context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else {
            throw LLMProviderError.invalidResponse("Failed to render the selected equation.")
        }

        let imageRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = imageRep.representation(using: .png, properties: [:]) else {
            throw LLMProviderError.invalidResponse("Failed to encode the captured equation image.")
        }

        return pngData
    }

    private func assembleContext(page: PDFPage, rect: CGRect, pageIndex: Int) -> [String] {
        let pageBounds = page.bounds(for: .mediaBox)
        let linePadding = max(24, min(72, rect.height * 0.4))
        let expandedRect = rect.insetBy(dx: 0, dy: -linePadding).intersection(pageBounds)
        let nearbyText = page.selection(for: expandedRect)?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var context: [String] = []
        if let nearbyText, nearbyText.count >= 24 {
            context.append("Nearby page text:\n\(nearbyText)")
        }

        if nearbyText == nil || nearbyText?.count ?? 0 < 80,
           let section = documentModel.chapters.flatMap(\.sections).first(where: { $0.pageRange.contains(pageIndex) }),
           !section.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.append("Enclosing section text:\n\(section.rawText)")
        }

        return context
    }

    private func failInline(_ message: String) {
        transition(to: .failed(message))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, case .failed(message) = self.state else { return }
            self.transition(to: .idle)
        }
    }

    private func transition(to newState: EquationCaptureState) {
        state = newState
    }

    private func updateCursor() {
        switch state {
        case .armed, .dragging:
            NSCursor.crosshair.set()
        default:
            NSCursor.arrow.set()
        }
    }

    private func drawStatusBadge(_ text: String, in dirtyRect: NSRect, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let badgeRect = CGRect(x: dirtyRect.minX + 16, y: dirtyRect.maxY - textSize.height - 28, width: textSize.width + 20, height: textSize.height + 12)

        let path = NSBezierPath(roundedRect: badgeRect, xRadius: 10, yRadius: 10)
        color.withAlphaComponent(0.92).setFill()
        path.fill()

        attributed.draw(at: CGPoint(x: badgeRect.minX + 10, y: badgeRect.minY + 6))
    }
}

final class EquationCaptureOverlayView: NSView {
    weak var controller: EquationCaptureController?
    private var trackingArea: NSTrackingArea?

    init(controller: EquationCaptureController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        controller?.shouldInterceptMouse == true ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        controller?.handleMouseEntered()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.handleMouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.handleMouseDown(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.handleMouseDragged(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        controller?.handleMouseUp(at: point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        controller?.drawOverlay(in: dirtyRect)
    }
}
