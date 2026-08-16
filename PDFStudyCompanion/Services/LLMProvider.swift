import AppKit
import Foundation

/// Every LLM backend (Bedrock, a direct API, or a local model) conforms
/// to this one protocol, so the rest of the app never talks to a
/// specific provider directly. Swapping backends is a settings change,
/// not a code change.
protocol LLMProvider {
    var supportsVision: Bool { get }

    /// `context` is pre-assembled by the caller (selection + section +
    /// retrieved passages) — the provider just sends it along.
    func generateText(prompt: String, context: [String]) async throws -> String
    func generateText(prompt: String, context: [String], images: [LLMImageInput]) async throws -> String
}

struct LLMImageInput {
    var data: Data
    var mimeType: String

    var bedrockFormat: String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpeg"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        default:
            return "png"
        }
    }
}

extension LLMProvider {
    var supportsVision: Bool { false }

    func generateText(prompt: String, context: [String], images: [LLMImageInput]) async throws -> String {
        if images.isEmpty {
            return try await generateText(prompt: prompt, context: context)
        }

        throw LLMProviderError.notImplemented("\(String(describing: Self.self)) does not support image input.")
    }
}

enum LLMProviderError: LocalizedError {
    case notImplemented(String)
    case missingConfiguration(String)
    case commandFailed(String)
    case invalidResponse(String)
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let provider):
            return "The provider \(provider) is not implemented."
        case .missingConfiguration(let message):
            return message
        case .commandFailed(let message):
            return message
        case .invalidResponse(let message):
            return message
        case .executableNotFound(let message):
            return message
        }
    }
}

/// Primary backend. Uses the AWS CLI's Bedrock runtime support so the app
/// can talk to Bedrock without bringing in the full AWS SDK.
struct BedrockProvider: LLMProvider {
    static let defaultProfile = "stormy-api"
    static let defaultRegion = "us-west-2"
    static let defaultModelID = "qwen.qwen3-235b-a22b-2507-v1:0"
    static let defaultVisionModelID = "us.anthropic.claude-sonnet-5"

    var region: String
    var modelID: String
    var visionModelID: String?
    var profile: String?

    static func configured() -> Self {
        BedrockProvider(
            region: defaultRegion,
            modelID: defaultModelID,
            visionModelID: defaultVisionModelID,
            profile: defaultProfile)
    }

    var supportsVision: Bool { visionModelID != nil }

    func testConnection() async throws -> String {
        try await generateText(prompt: "Reply with exactly OK.", context: [])
    }

    func testVisionConnection() async throws -> String {
        let imageData = try makeVisionTestImageData()

        return try await generateText(
            prompt: "You are receiving a simple visual test image. Reply with exactly OK.",
            context: [],
            images: [LLMImageInput(data: imageData, mimeType: "image/png")])
    }

    func generateText(prompt: String, context: [String]) async throws -> String {
        try await generateText(prompt: prompt, context: context, images: [])
    }

    func generateText(prompt: String, context: [String], images: [LLMImageInput]) async throws -> String {
        let requestID = UUID()
        let requestKind: BedrockRequestKind = images.isEmpty ? .text : .visual

        let selectedModelID: String
        if images.isEmpty {
            selectedModelID = modelID
        } else if let visionModelID {
            selectedModelID = visionModelID
        } else {
            throw LLMProviderError.notImplemented("This Bedrock configuration does not include a vision-capable model.")
        }

        await postStatus(
            BedrockRequestStatusEvent(
                id: requestID,
                kind: requestKind,
                phase: .started,
                message: nil))

        do {
            let messages = [
                BedrockMessage(
                    role: "user",
                    content: composeContent(prompt: prompt, context: context, images: images))
            ]
            let messagesData = try JSONEncoder().encode(messages)
            let messagesJSON = String(decoding: messagesData, as: UTF8.self)

            var arguments: [String] = []
            if let profile {
                arguments.append(contentsOf: ["--profile", profile])
            }
            arguments.append(contentsOf: [
                "--region", region,
                "bedrock-runtime", "converse",
                "--model-id", selectedModelID,
                "--messages", messagesJSON,
                "--output", "json"
            ])

            let output = try await runCommand(arguments, modelID: selectedModelID)
            let response = try decodeResponse(output)

            await postStatus(
                BedrockRequestStatusEvent(
                    id: requestID,
                    kind: requestKind,
                    phase: .succeeded,
                    message: nil))

            return response
        } catch {
            await postStatus(
                BedrockRequestStatusEvent(
                    id: requestID,
                    kind: requestKind,
                    phase: .failed,
                    message: error.localizedDescription))
            throw error
        }
    }

    private func postStatus(_ event: BedrockRequestStatusEvent) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .bedrockRequestStatusDidChange, object: event)
        }
    }

    private func composeContent(prompt: String, context: [String], images: [LLMImageInput]) -> [BedrockContentBlock] {
        var content: [BedrockContentBlock] = [
            .init(text: composeUserMessage(prompt: prompt, context: context))
        ]

        content.append(contentsOf: images.map { image in
            BedrockContentBlock(
                image: BedrockImage(
                    format: image.bedrockFormat,
                    source: BedrockImageSource(bytes: image.data.base64EncodedString())))
        })

        return content
    }

    private func composeUserMessage(prompt: String, context: [String]) -> String {
        guard !context.isEmpty else { return prompt }

        let joinedContext = context
            .enumerated()
            .map { index, item in "Context \(index + 1):\n\(item)" }
            .joined(separator: "\n\n---\n\n")

        return """
        Use the context below when it is relevant to the request.

        \(joinedContext)

        Request:
        \(prompt)
        """
    }

    private func makeVisionTestImageData() throws -> Data {
        let size = NSSize(width: 96, height: 96)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        NSColor.black.setStroke()
        let border = NSBezierPath(rect: NSRect(x: 8, y: 8, width: 80, height: 80))
        border.lineWidth = 4
        border.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let text = NSString(string: "OK")
        let textSize = text.size(withAttributes: attributes)
        let textOrigin = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2)
        text.draw(at: textOrigin, withAttributes: attributes)

        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let imageRep = NSBitmapImageRep(data: tiffData),
              let pngData = imageRep.representation(using: .png, properties: [:])
        else {
            throw LLMProviderError.invalidResponse("Failed to create the visual test image.")
        }

        return pngData
    }

    private func runCommand(_ arguments: [String], modelID: String) async throws -> Data {
        let executableURL = try resolveAWSCLIExecutableURL()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["AWS_REGION"] = region
            environment["AWS_DEFAULT_REGION"] = region
            environment["BEDROCK_MODEL_ID"] = modelID
            if let profile {
                environment["AWS_PROFILE"] = profile
            }
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                let error = stderr.fileHandleForReading.readDataToEndOfFile()

                guard process.terminationStatus == 0 else {
                    let message = String(decoding: error.isEmpty ? output : error, as: UTF8.self)
                    continuation.resume(throwing: LLMProviderError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }

                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: LLMProviderError.commandFailed("Failed to launch the AWS CLI: \(error.localizedDescription)"))
            }
        }
    }

    private func resolveAWSCLIExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let candidates = pathEntries + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]

        for directory in candidates {
            let executablePath = (directory as NSString).appendingPathComponent("aws")
            if fileManager.isExecutableFile(atPath: executablePath) {
                return URL(fileURLWithPath: executablePath)
            }
        }

        throw LLMProviderError.executableNotFound(
            "AWS CLI was not found. Install it separately and make sure /opt/homebrew/bin/aws or /usr/local/bin/aws exists on this Mac.")
    }

    private func decodeResponse(_ data: Data) throws -> String {
        let response = try JSONDecoder().decode(BedrockConverseResponse.self, from: data)
        let texts = response.output?.message?.content.compactMap(\.text).filter { !$0.isEmpty } ?? []

        guard let text = texts.first else {
            throw LLMProviderError.invalidResponse("Bedrock returned a response, but no text content was found.")
        }

        return text
    }
}

private struct BedrockMessage: Codable {
    var role: String
    var content: [BedrockContentBlock]
}

private struct BedrockContentBlock: Codable {
    var text: String?
    var image: BedrockImage?

    init(text: String) {
        self.text = text
        self.image = nil
    }

    init(image: BedrockImage) {
        self.text = nil
        self.image = image
    }
}

private struct BedrockImage: Codable {
    var format: String
    var source: BedrockImageSource
}

private struct BedrockImageSource: Codable {
    var bytes: String
}

private struct BedrockConverseResponse: Decodable {
    var output: BedrockOutput?
}

private struct BedrockOutput: Decodable {
    var message: BedrockMessage?
}

/// Calls a provider's own HTTP API directly, bypassing Bedrock. Useful
/// for testing or for models not yet available on Bedrock.
struct DirectAPIProvider: LLMProvider {
    var endpoint: URL
    var apiKey: String

    func generateText(prompt: String, context: [String]) async throws -> String {
        throw LLMProviderError.notImplemented("DirectAPIProvider")
    }
}

/// Talks to a model running on-device or on the local network (e.g.
/// Ollama on localhost). No data leaves the machine — this is the path
/// for privacy-sensitive PDFs.
struct LocalModelProvider: LLMProvider {
    var localEndpoint: URL   // e.g. http://localhost:11434

    func generateText(prompt: String, context: [String]) async throws -> String {
        throw LLMProviderError.notImplemented("LocalModelProvider")
    }
}
