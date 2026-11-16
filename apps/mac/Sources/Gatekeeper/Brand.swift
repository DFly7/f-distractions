import SwiftUI

/// Shared visual language for the app and the focus intervention.
enum FocusBrand {
    static let ink = Color(red: 0.09, green: 0.10, blue: 0.10)
    static let muted = Color(red: 0.43, green: 0.46, blue: 0.44)
    static let canvas = Color(red: 0.95, green: 0.95, blue: 0.93)
    static let lime = Color(red: 0.80, green: 0.96, blue: 0.35)
    static let accent = Color(red: 0.27, green: 0.39, blue: 0.16)
}

struct FocusMark: View {
    var size: CGFloat = 36
    var body: some View {
        Text("f/").font(.system(size: size * 0.65, weight: .black, design: .rounded))
            .tracking(-3).foregroundStyle(FocusBrand.ink)
            .frame(width: size, height: size)
            .background(FocusBrand.lime, in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

struct FocusButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, kind == .quiet ? 0 : 15).padding(.vertical, kind == .quiet ? 4 : 10)
            .contentShape(Rectangle())
            .foregroundStyle(kind == .primary ? Color.white : FocusBrand.ink)
            .background(kind == .primary ? FocusBrand.ink : kind == .secondary ? Color.white : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kind == .secondary ? FocusBrand.ink.opacity(0.14) : .clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


struct TaskRefinementStatus: View {
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(FocusBrand.accent).frame(width: 38, height: 38)
                    .background(FocusBrand.lime.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Refining your task with AI").font(.system(size: 13, weight: .semibold))
                    Text("Clarifying your goal and what belongs in this session.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel).buttonStyle(FocusButtonStyle(kind: .quiet))
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let phase = (sin(timeline.date.timeIntervalSinceReferenceDate * 2) + 1) / 2
                    Capsule().fill(FocusBrand.accent.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(FocusBrand.accent.opacity(0.65))
                                .frame(width: width * 0.28)
                                .offset(x: phase * width * 0.72)
                        }
                }.frame(height: 3)
            }.accessibilityLabel("Refining task in progress")
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(FocusBrand.ink.opacity(0.07)))
            .foregroundStyle(FocusBrand.ink)
    }
}
