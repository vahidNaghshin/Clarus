import Foundation

enum BedrockRequestKind: String {
    case text
    case visual

    var displayName: String {
        switch self {
        case .text:
            return "text"
        case .visual:
            return "visual"
        }
    }
}

enum BedrockRequestPhase {
    case started
    case succeeded
    case failed
}

struct BedrockRequestStatusEvent {
    let id: UUID
    let kind: BedrockRequestKind
    let phase: BedrockRequestPhase
    let message: String?
}

extension Notification.Name {
    static let bedrockRequestStatusDidChange = Notification.Name("bedrockRequestStatusDidChange")
}