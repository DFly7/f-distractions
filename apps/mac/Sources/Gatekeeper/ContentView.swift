import SwiftUI

private let ink = FocusBrand.ink
private let green = FocusBrand.accent
private let paper = FocusBrand.canvas

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var previewsExpanded = false
    @FocusState private var goalFocused: Bool
    @State private var section: WorkspaceSection = .focus
    @State private var detailsExpanded = false
    @State private var editingTask = false
    @State private var originalGoal = ""
    @State private var originalContext = ""
    @State private var modelsExpanded = false

    enum WorkspaceSection: String, CaseIterable {
        case focus = "Focus", activity = "Activity", settings = "Settings"
        var icon: String {
            switch self { case .focus: return "scope"; case .activity: return "clock.arrow.circlepath"; case .settings: return "slider.horizontal.3" }
        }
    }

    init(model: AppModel, initialSection: WorkspaceSection = .focus, showModelChoices: Bool = false) {
        self.model = model
        _section = State(initialValue: initialSection)
        _modelsExpanded = State(initialValue: showModelChoices)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            VStack(spacing: 0) {
                workspaceHeader
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !model.screenAccess { permissionCard }
                        if let error = model.error {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Something needs attention", systemImage: "exclamationmark.circle").font(.headline)
                                Text(error).font(.callout).textSelection(.enabled)
                                Button("Open settings") { section = .settings }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                        }
                        switch section {
                        case .focus:
                            if model.goal.isEmpty && !editingTask {
                                newTaskState
                            } else if !model.goal.isEmpty {
                                goalCard
                                if model.hasActiveSession || model.lastCheck != nil || model.checking { captureCard }
                            }
                        case .activity:
                            if model.timelineSession != nil {
                                SessionTimelineView(model: model)
                            } else {
                                emptyState("A little history in the making.", detail: "Your sessions and focus checks will appear here.", icon: "clock.arrow.circlepath")
                            }
                            if let error = model.historyError { Text(error).font(.caption).foregroundStyle(.orange) }
                        case .settings:
                            settingsContent
                        }
                    }.padding(24).frame(maxWidth: 980)
                        .frame(maxWidth: .infinity)
                }
                if model.hasActiveSession {
                    Divider()
                    sessionDock
                }
            }.background(paper)
        }.foregroundStyle(ink).buttonStyle(FocusButtonStyle()).preferredColorScheme(.light)
            .sheet(isPresented: $editingTask) { taskEditor }

    }

    private var workspaceHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.rawValue).font(.system(size: 22, weight: .semibold)).tracking(-0.6)
                Text(section == .focus ? "Give one thing your attention." : section == .activity ? "Your sessions, checks and course corrections." : "Make focus work for you.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if section == .focus {
                Button {
                    model.requestSessionExit(.newTask) { openTaskEditor() }
                } label: { Label("New task", systemImage: "plus") }
                    .disabled(model.checking || model.refiningTask)
                    .help(model.hasActiveSession ? "End this session and start a blank task" : "Start a blank task")
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
            .background(.white.opacity(0.55))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 9) {
                FocusMark(size: 32)
                Text("F Distractions").font(.system(size: 13, weight: .bold)).tracking(-0.4)
            }.padding(.top, 10)
            VStack(spacing: 6) {
                ForEach(WorkspaceSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.icon).frame(width: 18)
                            Text(item.rawValue)
                            Spacer()
                            if section == item { Circle().fill(FocusBrand.lime).frame(width: 5, height: 5) }
                        }.font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                            .foregroundStyle(section == item ? .white : .white.opacity(0.55))
                            .background(.white.opacity(section == item ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
            if model.hasActiveSession {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.session?.state == .paused ? "SESSION PAUSED" : "IN FOCUS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                        .foregroundStyle(FocusBrand.lime)
                    Text(String(format: "%02d:%02d", model.remainingSeconds / 60, model.remainingSeconds % 60))
                        .font(.system(size: 29, weight: .medium, design: .monospaced)).monospacedDigit()
                    Text(model.session?.goal ?? model.goal).font(.system(size: 11)).lineLimit(3).foregroundStyle(.white.opacity(0.6))
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Label("\(model.displayCount) screens connected", systemImage: "display.2")
                Label(model.screenAccess ? "Screen access ready" : "Screen access needed", systemImage: model.screenAccess ? "checkmark.shield" : "exclamationmark.shield")
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Divider().overlay(.white.opacity(0.1))
            Button { section = .settings } label: {
                HStack(spacing: 9) {
                    Circle().fill(model.account == nil ? Color.orange : FocusBrand.lime).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.connection).font(.system(size: 11, weight: .medium))
                        Text(model.account ?? "Set up your connection").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(16).foregroundStyle(.white).frame(maxHeight: .infinity).background(ink)
    }

    private func emptyState(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(green).padding(.bottom, 4)
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(50).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connection").font(.system(size: 17, weight: .semibold))
                HStack {
                    Label(model.connection, systemImage: "circle.fill").foregroundStyle(green)
                    Spacer()
                    Text(model.account ?? "Not signed in").foregroundStyle(.secondary).lineLimit(1)
                }.font(.system(size: 12))
                if let email = model.accountEmail { Text(email).font(.system(size: 13)).textSelection(.enabled) }
                HStack {
                    Button(model.signingIn ? "Waiting for sign-in…" : model.account == nil ? "Sign in with ChatGPT" : "Switch account") { Task { await model.signIn() } }
                        .disabled(model.connecting || model.checking || model.signingIn || model.hasActiveSession)
                    if model.signingIn {
                        Button("Cancel sign-in") { Task { await model.cancelSignIn() } }
                    }
                    Button("Reconnect") { Task { await model.connect() } }.disabled(model.connecting || model.checking)
                }
                if model.signingIn { Text("Finish signing in in your browser.").font(.caption).foregroundStyle(.secondary) }
                Text("Uses your existing Codex sign-in. Your subscription’s usage limits apply.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Monitoring").font(.system(size: 17, weight: .semibold))
                if !model.models.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AI model").font(.system(size: 12, weight: .medium))
                        Button { modelsExpanded.toggle() } label: {
                            HStack {
                                Image(systemName: "sparkles").foregroundStyle(green)
                                Text(model.models.first(where: { $0.id == model.selectedModel })?.name ?? model.selectedModel)
                                Spacer()
                                Text("Change").foregroundStyle(.secondary)
                                Image(systemName: modelsExpanded ? "chevron.up" : "chevron.down").font(.system(size: 10))
                            }.font(.system(size: 13)).padding(14).contentShape(Rectangle())
                                .background(paper, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(model.checking || model.refiningTask || model.hasActiveSession)
                        if modelsExpanded {
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(model.models) { item in
                                        Button {
                                            model.selectedModel = item.id; modelsExpanded = false
                                        } label: {
                                            HStack {
                                                Image(systemName: item.id == model.selectedModel ? "largecircle.fill.circle" : "circle")
                                                    .foregroundStyle(item.id == model.selectedModel ? green : Color.secondary)
                                                Text(item.name).font(.system(size: 13)).lineLimit(2)
                                                Spacer()
                                            }.padding(12).frame(maxWidth: .infinity).contentShape(Rectangle())
                                                .background(item.id == model.selectedModel ? green.opacity(0.06) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }.frame(height: min(CGFloat(model.models.count) * 43, 220))
                                .disabled(model.checking || model.refiningTask || model.hasActiveSession)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Background check gap").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 4) {
                        ForEach([15, 30, 60], id: \.self) { seconds in
                            Button { model.aiIntervalSeconds = seconds } label: {
                                Text("\(seconds) seconds").font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10).contentShape(Rectangle())
                                    .foregroundStyle(model.aiIntervalSeconds == seconds ? ink : Color.secondary)
                                    .background(model.aiIntervalSeconds == seconds ? Color.white : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                                    .shadow(color: .black.opacity(model.aiIntervalSeconds == seconds ? 0.05 : 0), radius: 2, y: 1)
                            }.buttonStyle(.plain)
                        }
                    }.padding(4).background(paper, in: RoundedRectangle(cornerRadius: 10))
                        .disabled(model.checking || model.hasActiveSession)
                }
                Text("App and tab changes get priority checks. These settings apply to your next session.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("Preview blur") { model.previewBlur() }.disabled(model.checking)
                    Button("One-off check") { model.check() }.disabled(!model.canCheck)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Permissions & diagnostics").font(.system(size: 17, weight: .semibold))
                permissionCard
                HStack {
                    Button("Screen recording settings") { model.openPermissions() }
                    Button("Open diagnostic log") { model.openLogs() }
                }
                Text("Session history is saved on this Mac. Screenshots are not stored in history.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var sessionDock: some View {
        HStack(spacing: 12) {
            if model.hasActiveSession {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.session?.state == .paused ? "Session paused" : "Focus session running").font(.system(size: 12, weight: .semibold))
                    Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("End") { model.requestSessionExit(.end) }
                if model.session?.state == .paused {
                    Button("Resume") { model.resumeSession() }.buttonStyle(FocusButtonStyle(kind: .primary))
                        .disabled(model.checking || model.connecting || model.account == nil)
                } else {
                    Button("Pause") { model.requestSessionExit(.pause) }.buttonStyle(FocusButtonStyle(kind: .primary))
                }

            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(.white)
    }

    private var permissionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.screenAccess ? "checkmark.shield" : "lock.display")
                .font(.system(size: 20)).foregroundStyle(model.screenAccess ? green : Color.orange)
            VStack(alignment: .leading, spacing: 9) {
                Text(model.screenAccess ? "Screen access is ready" : "Allow screen access to run your first check").font(.system(size: 13, weight: .semibold))
                if !model.screenAccess {
                    Text("Enable F Distractions in Screen & System Audio Recording. If you already clicked Allow, restart the app so macOS can apply the permission.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        if !model.permissionRequested { Button("Allow screen access") { model.requestScreenAccess() } }
                        Button("Open settings") { model.openPermissions() }
                        Button("Restart app") { model.restart() }
                    }.disabled(model.checking || model.hasActiveSession)
                }
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(model.screenAccess ? green.opacity(0.06) : Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func openTaskEditor() {
        originalGoal = model.goal; originalContext = model.taskContext
        editingTask = true
    }

    private var newTaskState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(ink.opacity(0.06), lineWidth: 1).frame(width: 118, height: 118)
                Circle().fill(.white).frame(width: 86, height: 86)
                Image(systemName: "scope").font(.system(size: 35, weight: .light)).foregroundStyle(ink)
            }.padding(.bottom, 10)
            Text("Make room for one thing.").font(.system(size: 30, weight: .semibold)).tracking(-1)
            Text("Choose what matters next. We’ll help you stay with it.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Button { openTaskEditor() } label: {
                Label("Create a task", systemImage: "plus").padding(.horizontal, 10).padding(.vertical, 3)
            }.buttonStyle(FocusButtonStyle(kind: .primary)).padding(.top, 8)
            Text("Your goal. Your time. Fewer distractions.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 16)
        }.padding(.vertical, 90).frame(maxWidth: .infinity)
    }

    private var taskEditor: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(originalGoal.isEmpty ? "What’s your focus?" : "Edit your task")
                        .font(.system(size: 25, weight: .semibold)).tracking(-0.7)
                    Text("A clear goal gives your session direction.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if model.refiningTask { model.cancelTaskSetup() }
                    model.goal = originalGoal; model.taskContext = originalContext
                    model.taskQuestion = nil; model.taskAnswer = ""
                    model.saveTaskDraft(); editingTask = false
                } label: { Image(systemName: "xmark").font(.system(size: 12)).padding(5) }
                    .buttonStyle(FocusButtonStyle(kind: .quiet)).help("Cancel changes")
            }
            .padding(28)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("I want to…").font(.system(size: 12, weight: .semibold))
                TextField("Finish the first draft of my assignment", text: $model.goal, axis: .vertical)
                    .font(.system(size: 18, weight: .medium)).lineLimit(2...3).textFieldStyle(.plain)
                    .focused($goalFocused).disabled(model.refiningTask)
                Rectangle().fill(ink.opacity(0.12)).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("A little context").font(.system(size: 12, weight: .semibold))
                    Text("Optional").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text("What does done look like? Which activities belong to this task?")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $model.taskContext).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(10).frame(height: 135)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.12)))
                    .disabled(model.refiningTask)
            }
            if let question = model.taskQuestion {
                Text(question).font(.system(size: 12, weight: .medium))
                TextField("Your answer", text: $model.taskAnswer).textFieldStyle(.roundedBorder).disabled(model.refiningTask)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(28)
            }
            Divider()
            Group {
            if model.refiningTask {
                TaskRefinementStatus { model.cancelTaskSetup() }
            } else {
                HStack {
                    Button { Task { await model.refineTask() } } label: {
                        Label(model.taskQuestion == nil ? "Refine with AI" : "Update brief", systemImage: "sparkles")
                    }.disabled(!model.canCheck)
                    Spacer()
                    Button(originalGoal.isEmpty ? "Create task" : "Save changes") {
                        model.saveTaskDraft(); editingTask = false
                    }.buttonStyle(FocusButtonStyle(kind: .primary))
                        .disabled(model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            }.frame(height: 104).padding(.horizontal, 28)
        }.frame(width: 550, height: 600).background(paper)
            .foregroundStyle(ink).buttonStyle(FocusButtonStyle()).preferredColorScheme(.light)
            .interactiveDismissDisabled()
            .onAppear { goalFocused = true }
    }

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(model.hasActiveSession ? "YOUR FOCUS" : "READY TO FOCUS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if model.hasActiveSession {
                    Text(model.session?.state == .paused ? "PAUSED" : "LIVE")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(green)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(FocusBrand.lime.opacity(0.3), in: Capsule())
                } else {
                    Button { openTaskEditor() } label: { Label("Edit task", systemImage: "pencil") }
                        .disabled(model.checking || model.refiningTask)
                }
            }
            Text(model.goal).font(.system(size: 26, weight: .semibold)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !model.taskContext.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Task context").font(.system(size: 12, weight: .semibold))
                    Text(model.taskContext).font(.system(size: 13)).lineSpacing(4)
                        .foregroundStyle(FocusBrand.muted).lineLimit(detailsExpanded ? nil : 5)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if model.taskContext.count > 200 {
                        Button(detailsExpanded ? "Show less" : "Read full context") { detailsExpanded.toggle() }
                            .buttonStyle(FocusButtonStyle(kind: .quiet))
                    }
                }
            }
            if model.hasActiveSession {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%02d:%02d", model.remainingSeconds / 60, model.remainingSeconds % 60))
                        .font(.system(size: 48, weight: .medium, design: .monospaced)).tracking(-2).monospacedDigit()
                    Text("remaining").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                ProgressView(value: Double((model.session?.durationSeconds ?? 1) - model.remainingSeconds),
                             total: Double(model.session?.durationSeconds ?? 1)).tint(green)
            } else {
                Divider()
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Session length").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button { model.sessionMinutes = max(1, model.sessionMinutes - 5) } label: {
                                Image(systemName: "minus").frame(width: 28, height: 30).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Shorter session")
                            TextField("Minutes", value: $model.sessionMinutes, format: .number)
                                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                .multilineTextAlignment(.center).textFieldStyle(.plain).frame(width: 36)
                                .accessibilityLabel("Session length in minutes")
                            Text("min").font(.system(size: 12)).foregroundStyle(.secondary)
                            Button { model.sessionMinutes = min(240, model.sessionMinutes + 5) } label: {
                                Image(systemName: "plus").frame(width: 28, height: 30).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Longer session")
                        }.padding(.horizontal, 5).padding(.vertical, 3)
                            .background(paper, in: RoundedRectangle(cornerRadius: 9))
                    }.disabled(model.checking)
                    Spacer()
                    Button { model.startSession(); editingTask = false; detailsExpanded = false } label: {
                        Label("Start session", systemImage: "play.fill").padding(.horizontal, 8).padding(.vertical, 4)
                    }.buttonStyle(FocusButtonStyle(kind: .primary)).disabled(!model.canStartSession)
                }
            }
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ink.opacity(0.06)))
    }

    private var statusText: String {
        if model.session?.state == .paused { return "Resume when you’re ready." }
        if model.hasActiveSession { return "Monitoring all \(model.displayCount) screens." }
        if model.checking { return model.countdown.map { "Capturing in \($0)… Switch to your work now." } ?? model.stage }
        return "Start when you’re ready. We’ll keep watch from the menu bar."
    }

    var captureCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("LAST COMPLETED CHECK").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.analysisInFlight ? green : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                    Text(model.analysisInFlight ? "Updating…" : model.countdown != nil ? "Capturing soon" : model.lastCheck == nil ? "Waiting" : "Last result")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(width: 95, alignment: .trailing)
                Button("Check now") { model.check() }
                    .disabled(!model.canCheck || model.policy.pendingTrigger == .manual)
            }.frame(height: 34)
            // Keep the same footprint for idle, first check, refresh and completed results.
            HStack(alignment: .top, spacing: 12) {
                let status = model.verdict?.status
                Image(systemName: status == "on_task" ? "checkmark.circle.fill" : status == "off_task" ? "arrow.uturn.backward.circle.fill" : "scope")
                    .font(.system(size: 23)).foregroundStyle(status == "off_task" ? Color.orange : green)
                    .frame(width: 26)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status == "on_task" ? "You’re on track." : status == "off_task" ? "Time to come back." : model.verdict != nil ? "Let’s get some context." : "Your first check is on its way.")
                            .font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                        Text(model.verdict?.reason ?? "Keep working. The result will appear here when the check finishes.")
                            .font(.system(size: 13)).textSelection(.enabled)
                        if let nextStep = model.verdict?.nextStep {
                            Text(nextStep).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.hidden)
            }.frame(height: 132, alignment: .top)
            Text(model.lastCheck.map { "Latest capture \($0.formatted(date: .omitted, time: .shortened)) · \(model.screenshots.count) screens" } ?? "Waiting for the first completed check")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 14, alignment: .leading)
            Text(model.correctionNote ?? model.interventionNote ?? "Screens are checked against your task context.")
                .font(.system(size: 11)).foregroundStyle(model.correctionNote != nil ? green : model.interventionNote != nil ? Color.orange : Color.secondary)
                .lineLimit(2).frame(height: 30, alignment: .topLeading)
            VStack(spacing: 9) {
                ForEach(0..<max(model.displayCount, model.verdict?.screens.count ?? 0), id: \.self) { index in
                    let screen = model.completedVerdict(forPhysicalIndex: index + 1)
                    HStack {
                        Text("Screen \(index + 1)").fontWeight(.medium)
                        Spacer()
                        Text(screen?.status.replacingOccurrences(of: "_", with: " ").capitalized ?? "Awaiting check")
                            .foregroundStyle(screen?.status == "off_task" ? Color.orange : Color.secondary)
                    }.font(.system(size: 11)).frame(height: 16)
                }
            }
            Button { previewsExpanded.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: previewsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Image(systemName: "photo.on.rectangle")
                    Text(previewsExpanded ? "Hide screenshots & reasons" : "View screenshots & reasons")
                    Spacer()
                    Text("\(model.screenshots.count)").foregroundStyle(.secondary)
                }.font(.system(size: 12, weight: .medium)).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.screenshots.isEmpty)
            if previewsExpanded {
                ForEach(Array(model.screenshots.enumerated()), id: \.element.id) { index, capture in
                    let screen = model.verdict?.screens.first { $0.screenIndex == index + 1 }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(capture.label).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(screen?.status.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unassessed")
                                .font(.system(size: 11)).foregroundStyle(screen?.status == "off_task" ? Color.orange : green)
                        }
                        if let capturedAt = model.assessmentTimes[capture.id] {
                            Text("Captured \(capturedAt.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Image(nsImage: capture.image).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity).frame(height: 230)
                            .background(ink.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(screen?.reason ?? model.verdict?.reason ?? "No reason provided.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(16).background(paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(ink.opacity(0.07)))
            .transaction { $0.animation = nil }
    }
}
