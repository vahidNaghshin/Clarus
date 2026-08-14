import Foundation

/// Every LLM backend (Bedrock, a direct API, or a local model) conforms
/// to this one protocol, so the rest of the app never talks to a
/// specific provider directly. Swapping backends is a settings change,
/// not a code change.
protocol LLMProvider {
    /// `context` is pre-assembled by the caller (selection + section +
    /// retrieved passages) — the provider just sends it along.
    func generateText(prompt: String, context: [String]) async throws -> String
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

    var region: String
    var modelID: String
    var profile: String?

    static func configured() -> Self {
        BedrockProvider(
            region: defaultRegion,
            modelID: defaultModelID,
            profile: defaultProfile)
    }

    func testConnection() async throws -> String {
        try await generateText(prompt: "Reply with exactly OK.", context: [])
    }

    func generateText(prompt: String, context: [String]) async throws -> String {
        let messages = [
            BedrockMessage(
                role: "user",
                content: [.init(text: composeUserMessage(prompt: prompt, context: context))])
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
            "--model-id", modelID,
            "--messages", messagesJSON,
            "--output", "json"
        ])

        let output = try await runCommand(arguments)
        return try decodeResponse(output)
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

    private func runCommand(_ arguments: [String]) async throws -> Data {
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
    var content: [BedrockContent]
}

private struct BedrockContent: Codable {
    var text: String
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
