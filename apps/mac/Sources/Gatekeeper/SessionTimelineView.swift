import SwiftUI

struct SessionTimelineView: View {
    @ObservedObject var model: AppModel
    @State private var historyExpanded = false
    init(model: AppModel, showHistory: Bool = false) {
        self.model = model
        _historyExpanded = State(initialValue: showHistory)
    }
    var body: some View {
        if let session = model.timelineSession {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("YOUR SESSION").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                    Spacer()
                    if !model.history.isEmpty {
                        Button { historyExpanded.toggle() } label: {
                            Label(historyExpanded ? "Hide sessions" : "Browse sessions", systemImage: "clock.arrow.circlepath")
                        }

                    }
                }
                if historyExpanded {
                    ScrollView {
                        VStack(spacing: 6) {
                            Button {
                                model.reviewedSessionID = nil; historyExpanded = false
                            } label: {
                                HStack {
                                    Text("Current / latest session").font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }.padding(12).contentShape(Rectangle()).background(FocusBrand.canvas, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                            ForEach(model.history) { item in
                                Button {
                                    model.reviewedSessionID = item.id; historyExpanded = false
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: model.reviewedSessionID == item.id ? "checkmark.circle.fill" : "clock")
                                            .foregroundStyle(FocusBrand.accent).padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.goal).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        .background(FocusBrand.canvas, in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: 260)
                }
                Text(session.goal).font(.system(size: 18, weight: .semibold))
                HStack(spacing: 16) {
                    Label(session.state.rawValue.capitalized, systemImage: "clock")
                    Text("\(session.aiChecks) AI checks")
                    Text("\(session.skippedSamples) local samples skipped")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(Array(session.events.suffix(50).reversed())) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(eventColor(event.kind)).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(eventTitle(event.kind)).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(event.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                            }.font(.system(size: 10, design: .monospaced))
                            if let trigger = event.trigger {
                                Text([trigger, event.app].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Text(event.reason).font(.system(size: 12)).textSelection(.enabled)
                            if let nextStep = event.nextStep {
                                Text(nextStep).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 5)
                }
                Text("Latest 50 events shown. Session text is saved on this Mac; screenshots are not stored in history.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(FocusBrand.ink).preferredColorScheme(.light)
        }
    }
    private func eventTitle(_ kind: String) -> String {
        switch kind {
        case "on_task": return "On track"
        case "off_task": return "Off task"
        case "unsure": return "Uncertain"
        case "error": return "Check failed"
        case "intervention": return "Focus overlay shown"
        case "correction": return "Marked relevant by you"
        case "returning": return "Returning to work"
        case "rechecking": return "Fresh check queued"
        default: return kind.capitalized
        }
    }
    private func eventColor(_ kind: String) -> Color {
        switch kind {
        case "on_task": return .green
        case "off_task": return .orange
        case "error": return .red
        case "correction": return .blue
        case "intervention": return .orange
        default: return .gray
        }
    }
}
