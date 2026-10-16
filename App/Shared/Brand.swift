import MountliCore
import SwiftUI

extension Color {
    static let mountliEmerald = Color(red: 0.07, green: 0.47, blue: 0.34)
    static let mountliInk = Color(red: 0.08, green: 0.11, blue: 0.10)
    static let mountliMist = Color(red: 0.93, green: 0.97, blue: 0.95)

    /// Window background behind dashboard cards.
    static var mountliCanvas: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color(uiColor: .systemGroupedBackground)
        #endif
    }

    /// Raised card surface that adapts to light and dark mode.
    static var mountliCard: Color {
        #if os(macOS)
            Color.primary.opacity(0.045)
        #else
            Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

struct MountliMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.mountliEmerald.gradient)
            Image("MountliMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let status: MountStatus

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(status.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.12), in: Capsule())
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

extension View {
    /// Presents an error from inside a sheet. The window-level error sheet cannot appear
    /// while another sheet is up, so in-sheet flows must report failures themselves.
    func errorAlert(_ message: Binding<String?>, title: LocalizedStringKey = "Something went wrong") -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
