import MountliCore
import SwiftUI

extension Color {
    static let mountliEmerald = Color(red: 0.07, green: 0.47, blue: 0.34)
    static let mountliInk = Color(red: 0.08, green: 0.11, blue: 0.10)
    static let mountliMist = Color(red: 0.93, green: 0.97, blue: 0.95)
}

struct MountliMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.mountliEmerald.gradient)
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let status: MountStatus

    private var color: Color {
        switch status {
        case .online: .green
        case .connecting, .transferring: .blue
        case .degraded, .authenticationRequired: .orange
        case .offline, .disabled, .paused: .secondary
        case .error: .red
        }
    }

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct ActionFailureView: View {
    let title: String
    let message: String
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.title2.bold())
                        Text(message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
                    .padding(28)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
            .frame(minWidth: 460, idealWidth: 520, maxWidth: 620, minHeight: 300, idealHeight: 360, maxHeight: 540)
        #endif
    }
}
