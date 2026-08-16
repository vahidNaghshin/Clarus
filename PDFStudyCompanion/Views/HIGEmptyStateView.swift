import AppKit
import SwiftUI

struct HIGEmptyStateView: View {
    let symbolName: String
    let symbolSize: CGFloat
    let symbolWeight: Font.Weight
    let title: String
    let titleSize: CGFloat
    let titleWeight: Font.Weight
    let subtitle: String
    let subtitleSize: CGFloat
    let subtitleMaxWidth: CGFloat
    let verticalCenterRatio: CGFloat
    let buttonTitle: String?
    let buttonAction: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: symbolSize, weight: symbolWeight))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

                Text(title)
                    .font(.system(size: titleSize, weight: titleWeight))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: subtitleMaxWidth)

                if let buttonTitle, let buttonAction {
                    Button(buttonTitle, action: buttonAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity)
            .position(x: proxy.size.width / 2, y: proxy.size.height * verticalCenterRatio)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}