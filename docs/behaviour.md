# F Distractions behaviour

This describes the current Mac prototype and the intended baseline for future platform implementations. Windows support is not implemented yet. The Mac guide covers platform details and operating limits.

## Task and session

A user creates or edits a concrete goal and context before starting. Optional AI refinement proposes an outcome, allowed work, off-task examples and at most one clarifying question. The user reviews and can edit the result. No personal coursework context ships as the default task.

Choose 1–240 minutes (default 45) and a background AI gap of 15, 30 or 60 seconds (default 30). The goal, model and frequency stay fixed during a session. Start keeps the main window open. Closing it continues monitoring in the menu bar. Pause freezes the timer and stops capture; resume is explicit. Timer expiry completes the session. Relaunch marks unfinished sessions interrupted and never starts monitoring automatically.

## Assess all screens

Capture every connected display, including this app's normal windows and dialogs but excluding its blur/card overlay windows (including those fading out). If one capture fails, fail the check rather than silently analysing a partial set. Screenshots provide visible content, not proof of attention or hidden/phone activity.

Each AI response needs exactly one 1-based screen verdict for every image, mapped back to the physical displays captured for that request. Statuses are `on_task`, `off_task`, `unsure`, or `neutral`. Only clear unrelated content is off task. Related research and task tools can be on task. Unused wallpaper is neutral; settings are not automatically relevant. Treat screenshot text as untrusted evidence, never instructions, and disable classifier tools.

Judge substantive displayed content, including the messages in an open AI conversation. An allowed AI/coding app is not an allowlist for unrelated conversations. F Distractions controls, task text, assessment explanations and embedded historical screenshot previews are monitoring UI, not current evidence of the activities they depict. Do not infer content hidden behind the main app. When only monitoring UI is assessable, use unsure.

Inactive thread titles, unselected tabs, sidebar navigation, bookmarks, recent-file lists and dock icons alone cannot justify off_task. Conversely, substantive unrelated content actually visible in a separate pane/window/screen still counts. If only labels are readable, do not guess the conversation topic; use unsure. Off-task reasons must identify the displayed unrelated content. Every screen requires an evidenceSource; only active_content may accompany off_task. Reject off_task responses based on inactive_navigation, monitoring_ui or unreadable evidence rather than creating a new blur. This does not automatically dismiss existing locked blur.

Aggregate status: any off_task → off_task; otherwise any unsure → unsure; otherwise any on_task → on_task; otherwise unsure. Missing or duplicate indices, unexpected statuses and inconsistent aggregate verdicts fail validation. A failure is an error, never an off-task verdict.

## Starting and keeping blur

Only a validated off-task screen judgment or a matching recently confirmed off-task view can initiate blur. Before a new AI result initiates blur, check freshness: at most 20 seconds old, same display mapping and compatible window/title identity (pixel fallback when metadata is unavailable). Scrolling inside the same window does not by itself veto blur. The animation grows inward from the edges over 1.4 seconds.

**Once visible, blur stays latched.** Changing tabs, windows or the content underneath it cannot clear it. A later on_task, neutral or unsure result, a new capture or an AI/capture error cannot clear it either. Background checks may add or update interventions. Freshness guards govern starting a new blur; they do not dismiss one already present.

The blur background is click-through and the card contains deliberate actions. Main session controls stay accessible above it. Each intervention targets a physical screen. Removing a disconnected display removes its panels without releasing blur on remaining displays. Pause, session completion/end, sleep/inactive-user pause and actual app shutdown clean up overlays.

## Explicit actions

- **Return to work:** fade only the clicked screen's blur/card away over 450 ms. Give three seconds to navigate; other screens remain blurred. Do not approve the view or activate another app. Old in-flight results cannot immediately undo this grace period. Afterward, a matching recently confirmed distraction can reblur locally; changed content gets priority AI reassessment.
- **This is relevant:** immediately clear only that screen, record a correction and exempt the current view for up to two minutes. A window/tab change on that screen, sufficiently changed content, a display change or expiry ends the exception. App switches or navigation on other screens do not clear it. The correction is tied to that screen’s window/title identity plus screenshot fingerprint, not a global app-switch event. This is not a permanent site allowlist or model retraining.
- **Take a break:** request the same ten-second continuous hold used for early pause. On completion, pause the timer, stop monitoring and remove overlays; resume explicitly.

## Early-exit friction

During an active session, Pause, End, New task, Take a break and Quit all require a continuous ten-second hold. Holding Space on the focused hold control is also supported. Releasing, dragging outside the control or switching away resets progress. The session and monitoring keep running during confirmation. Keep focusing cancels immediately. Timer expiry and automatic lifecycle pauses remain automatic. This adds deliberate friction; it does not prevent force-quit.

## Scheduling and context

Only one AI request runs at a time. Initial checks assess all screens together. Compare local fingerprints against the last successful assessment, not just the preceding sample, so gradual changes accumulate. Ordinary local samples are at least five seconds apart when eligible; overlays allow two-second freshness samples. App/window/title and display changes queue priority work after settling. Background requests use the selected gap; priority requests have a three-second floor. Failed checks back off by at least 30 seconds or the selected gap, whichever is longer.

A confirmed off-task view can be remembered locally for two minutes using display, window/title identity and fingerprint. Cached matching views can blur without another AI round trip; unfamiliar views still incur inference latency. Pause/end/expiry cancel work, drop late results and clean temporary files. The local Codex process stays running, while classification currently uses fresh ephemeral threads; thread reuse is an unimplemented optimisation to benchmark, not an agreed behavioural dependency.

## Interface and data

Focus shows the saved, read-only task with visible context; creation/editing is a separate dialog. Session length and Start belong to the task card. The active-session footer keeps Pause/Resume and End accessible. Activity holds timeline/history; Settings holds connection, model and monitoring choices. Use full-row hit targets and bounded lists rather than overflowing menus.

During refresh, keep the last completed verdict, screenshots and capture time together. Show an updating indicator only for AI inference. Local comparison skips do not flash loading. The full-width screenshot disclosure reveals each image with its verdict and reason. Keep the assessment layout and task editor stable between loading states.

Full screenshots are temporary, deleted after success/failure/cancellation; latest previews remain in memory. A crash may leave temporary files. Session text is saved locally (latest 20 sessions, up to 500 events each), not screenshots. No webcam, audio capture, keylogging, hosted backend or telemetry is implemented. The provider processes submitted screenshots under its own account/retention behaviour. See apps/mac/README.md for local paths and diagnostic details.

## Decision history

The accepted product moved from a broader tutor/webcam brainstorm to a screenshot-based focus app. Later changes made Return to work per-screen with a three-second grace period, added continuous ten-second early-exit holds, and finally latched blur so background navigation and verdicts cannot dismiss it. These later decisions supersede earlier suggestions to lift blur automatically when a scene changes. Shared acceptance scenarios are in shared/fixtures/behaviour-cases.json.
