import SwiftUI

private enum BedrockBannerStyle {
    case progress
    case success
    case failure
}

private struct BedrockBannerState {
    let text: String
    let style: BedrockBannerStyle
}

private struct BedrockStatusBannerModifier: ViewModifier {
    @State private var activeRequestCount = 0
    @State private var bannerState: BedrockBannerState?
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if let bannerState {
                    HStack(spacing: 10) {
                        switch bannerState.style {
                        case .progress:
                            ProgressView()
                                .controlSize(.small)
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }

                        Text(bannerState.text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 320, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                    .padding(.top, 14)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: bannerState != nil)
            .onReceive(NotificationCenter.default.publisher(for: .bedrockRequestStatusDidChange)) { notification in
                guard let event = notification.object as? BedrockRequestStatusEvent else { return }
                handle(event)
            }
    }

    private func handle(_ event: BedrockRequestStatusEvent) {
        hideTask?.cancel()

        switch event.phase {
        case .started:
            activeRequestCount += 1
            bannerState = BedrockBannerState(
                text: "Sending request to Bedrock \(event.kind.displayName) model…",
                style: .progress)

        case .succeeded:
            activeRequestCount = max(0, activeRequestCount - 1)
            bannerState = BedrockBannerState(
                text: "Bedrock \(event.kind.displayName) model replied.",
                style: .success)
            scheduleDismissal()

        case .failed:
            activeRequestCount = max(0, activeRequestCount - 1)
            let detail = event.message.map { ": \($0)" } ?? ""
            bannerState = BedrockBannerState(
                text: "Bedrock \(event.kind.displayName) request failed\(detail)",
                style: .failure)
            scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                if activeRequestCount > 0 {
                    bannerState = BedrockBannerState(
                        text: "Sending request to Bedrock…",
                        style: .progress)
                } else {
                    bannerState = nil
                }
            }
        }
    }
}

extension View {
    func bedrockStatusBanner() -> some View {
        modifier(BedrockStatusBannerModifier())
    }
}