# F Distractions · Mac focus sessions

Set a goal and a duration, start a session, then work. Gatekeeper quietly samples all connected screens, logs whether their visible content matches your goal, and fades a blur over screens with fresh, clear off-task content. The overlay shows your goal and lets you return to work, correct its judgment, or take a break.

## Build and open

Requires macOS 14+, Xcode command-line tools, a valid Apple Development signing identity, and [Codex CLI](https://learn.chatgpt.com/docs/cli) (`npm install -g @openai/codex`). Quit Gatekeeper before rebuilding.

```sh
cd apps/mac
bash scripts/build-app.sh
open "dist/F Distractions.app"
```

The app starts its own local `codex app-server` in a dedicated working folder and uses your existing Codex ChatGPT sign-in. If needed, **Sign in with ChatGPT** opens Codex’s browser flow. Account email and plan are shown locally so you can verify the account. Subscription usage limits apply. API-key accounts are deliberately rejected in this POC.

## Workspace

- **Focus** keeps the goal and latest assessment together. The saved goal is read-only, with context visible beneath it. **Edit task** opens a dedicated dialog for the goal and context; **Save changes** saves them, and closing the dialog restores the previous values. With no task, Focus shows a simple **Create a task** empty state. Longer summaries have **Read full context**. **New task** clears the draft; during a session it ends the current session first.
- Session length and Start sit together at the bottom of the task card. Once running, the fixed bottom bar keeps Pause/Resume and End available in every tab.
- **Activity** holds the session timeline and an inline **Browse sessions** list with wrapped task titles and dates.
- **Settings** holds the ChatGPT connection, a bounded inline model list, a three-option background gap selector, blur preview, one-off check and diagnostics. The sidebar shows connection and screen-access status without a large permission banner when access is ready.

## Use

1. Grant Screen Recording access. The permission card should say **Screen access is ready**. If macOS requires it, use **Restart Gatekeeper** after granting access.
2. Enter a concrete goal and task details. **Help define my task** asks the model for an editable outcome, allowed work, distractions and (if needed) one clarifying question. Review the brief before starting. Choose a duration from 1–240 minutes (default 45), and an AI request gap of 15, 30 or 60 seconds (default 30).
3. Click **Start session**. The window stays open; minimise or close it when ready. Monitoring continues in the menu bar. The first sample starts immediately. The three-second countdown is only used for manual one-off checks.
4. Gatekeeper stays in the background. Its menu-bar icon shows the remaining time. A fresh off-task judgment can fade a blur over the affected screen; other screens stay usable. Open the app to see the latest per-screen assessment and the session timeline.
5. **Pause** removes overlays, stops captures and freezes the remaining time. **Resume** continues. **End session**, timer expiry and quitting stop monitoring. Sleep/display sleep or an inactive user session pauses monitoring; resuming is explicit.

Goal, model and frequency stay fixed during a session. **Check now** queues an assessment while respecting the same request limit. **One-off check / Check again** remains available outside a session with a three-second countdown. Manual one-off checks return the window and do not show focus overlays. Automatic checks do not activate the main window; off-task overlays use nonactivating native panels.

The timeline records each judgment’s time, trigger, foreground app, explanation and suggested next step. Errors are shown as errors, never off-task judgments. They cannot create a new blur or clear an existing locked blur. Previous sessions are available in **History**. The latest completed screenshot previews are collapsed beneath the assessment. During refreshes, the previous verdict, screenshots and capture time remain visible together. A small Updating indicator appears only during AI inference; local comparison skips do not replace the card. The assessment keeps a stable layout, and the task editor has a fixed-size scrolling form with a reserved action area.

## Stopping early

During an active session, **Pause**, **End**, **New task**, **Take a break**, and **Quit** open the same hold confirmation. Keep the mouse button down (or focus the hold control and hold Space) for ten uninterrupted seconds. Releasing, dragging outside the control, or switching away resets progress. Monitoring and the timer continue while the confirmation is open. **Keep focusing** cancels it immediately. Closing the main window continues monitoring; Cmd-Q and the menu-bar Quit action also use the gate. Resume and quitting outside a session are immediate. Timer expiry and automatic sleep/inactive-user pauses remain automatic.

## Focus overlays

Each model response must include exactly one indexed verdict for every captured screen: on task, off task, uncertain or neutral. Missing, duplicate or contradictory screen judgments fail validation. Only explicit off-task screen verdicts can trigger blur, and image indices map back to the physical display IDs captured in that request.

Before showing an overlay, Gatekeeper takes a fresh local sample. Results older than 20 seconds or from a changed display arrangement are withheld and queued for reassessment. Each screen tracks its visible app window and a transient hash of the window title. Scrolling within the same window no longer vetoes blur. A different window or title (for example a browser tab switch) invalidates the old judgment. If window metadata is unavailable, pixel comparisons and a second local sample provide a conservative fallback. These are heuristics: navigation that preserves a title may be missed.

The card leads with your goal as the main headline, followed by a clearly labelled **Why this screen was blurred** panel with the per-screen reason. This describes the blur trigger, which remains locked until an explicit action even if later content changes.

The blur grows inward from all four edges over 1.4 seconds. Its background is click-through; a separate card has the deliberate actions. Native panels stay above ordinary windows without activating Gatekeeper. Cmd-Tab and the menu bar remain available. The panels have no close button and Escape does not dismiss them.

- **Return to work** fades only the clicked screen’s blur/card away over 450 ms. Other screens remain guarded. After three seconds, a local sample can immediately restore blur if the recently confirmed distraction still matches its window/title and fingerprint. Changed views get a priority AI assessment. Earlier in-flight screenshots cannot reapply blur to the returning screen. The button does not approve the distraction or activate another app. Fresh AI judgments still incur inference latency; error backoff can delay them.
- **This is relevant** immediately removes that screen’s overlay and records a correction. The current view is exempt for up to two minutes. This is a local view-scoped exception, not a permanent site/app whitelist or model retraining. It ends when that screen’s own window/tab or content changes, on a display change, or at expiry; expiry queues reassessment. App switches on another monitor do not clear the correction.
- **Take a break** opens the ten-second hold confirmation. After completing the hold, overlays are removed and monitoring and the timer pause. Resuming is explicit.

Once shown, a blur stays locked until an explicit **Return to work**, **This is relevant**, or confirmed **Take a break** action, or the session ends. Background changes, fresh on-task/neutral verdicts, and check errors do not silently clear it. Disconnected displays are removed; remaining connected screens keep their blur. Return to work still lifts only the clicked screen for three seconds before the normal recheck/cache policy can reapply it. Opening the main app keeps session controls above the blur. Only intervention blur/card windows remain excluded from screenshots; normal app windows and dialogs are included.

The full-width **View screenshots & reasons** row expands the latest completed assessment into per-screen images, verdicts and reasons.

## How checks are scheduled

- The initial check assesses all connected screens together.
- When eligible for a request and idle, local screen samples are at least five seconds apart. With overlays present, two-second local samples check scene freshness even during request cooldowns. Sampling is suspended during AI requests and pauses.
- Each display is resized to a 160×90 grayscale fingerprint. A pixel counts as changed when its brightness differs by more than 18/255. A display is considered changed when at least 2.5% of its fingerprint pixels differ.
- Comparisons use the **last successful AI assessment** as the baseline, allowing gradual changes to accumulate. Display IDs and source dimensions detect topology changes; image order alone is irrelevant.
- Native desktop/Space changes, app activations, visible window/title changes (polled every 250 ms), and display changes queue priority reassessments after a 350 ms settling delay, even if screenshots look similar. Rapid switches coalesce into one pending trigger. No Accessibility permission, browser extension, keyboard logging or page-text extraction is used.
- Unchanged screens skip the model call. A queued event or meaningful visual change sends one screenshot per connected display in a single Codex request. Only one request runs at a time, and background request starts respect the selected gap. Priority app/window/tab changes and Check now use a three-second request floor. Supported models use low reasoning effort to reduce latency; unseen views still wait for inference.
- Substantial settled content changes are detected by local probes roughly once per second, including during inference/cooldowns, so thread switches that keep the same window title can receive priority. Two samples 250 ms apart ignore moving pixels; at least 20% must be stable, and at least 18% of that stable region must have changed. These probes do not upload images or flash loading states.
- A confirmed app/window/title change supersedes an older in-flight check. Pixel-only updates queue the next check without cancelling the current request; a fresh pixel check withholds a new blur if the assessed content has changed. Codex turn cancellation keeps the existing process/connection open, and obsolete replies are discarded. The latest view remains queued; the three-second request floor and error backoff still apply. Previous completed results and locked blur remain visible. Setup and total request timings are logged without screenshot contents.
- Events occurring during analysis remain queued for the next eligible assessment. Failed checks preserve the last successful baseline and retry no sooner than 30 seconds or the selected gap, whichever is longer. Failed analysis connections are reopened; failed reconnections are also rate limited.
- Timer expiry, pause and end cancel in-flight work, discard late results and clean temporary files. Monitoring never automatically restarts on launch; unfinished saved sessions are marked interrupted.

For up to ten minutes within the current session (at most 40 entries), a recently confirmed off-task view can be recalled locally when its display, window/title identity and screenshot fingerprint match, starting blur without waiting for another AI verdict. Changed windows/tabs or stable content cannot use that cache. A second local sample tolerates moving pixels such as video while keeping stable content matched. Marking a view relevant removes its cached false positive.

Pre-intervention freshness samples are local and do not cause additional model calls. Images retain up to 1600 pixels on their longest side for model analysis. The model treats unrelated activity visible on any screen as off task. Unused wallpaper is neutral when another screen shows work. Settings are off task unless the goal explicitly involves settings. Screenshots establish visible content, not attention, progress or whether you picked up your phone. Visual comparison is a heuristic: small meaningful changes may be missed and animations can cause unnecessary checks. The selected gap controls background requests, not priority checks or an exact assessment interval.

## Data

Screen Recording permission is required. Every connected display is included at capture time, including the normal app window and dialogs, and excluding only its intervention blur/card windows. Captures happen in a short sequence, not simultaneously. If one display fails, partial files are deleted and the check fails instead of silently evaluating only some screens.

Full screenshots are temporary files private to the user, deleted after comparison-only skips, success, failure or cancellation. Only the latest analysed previews remain in memory until cleared/replaced or the app quits. A crash can leave files in the macOS temporary directory. There is no audio capture or webcam use. Window IDs and title hashes stay in memory; raw window titles are neither saved nor separately sent to the model.

Session **text** (including goals, app names and model explanations) is saved locally in `~/Library/Application Support/Gatekeeper/sessions.json`, retaining the latest 20 sessions and up to 500 events per session. The UI displays the latest 50 events from the selected session. Screenshots are not stored in history. Goals, task details, duration, gap and selected model are saved in UserDefaults. History write/load errors are surfaced in the app.

**Open diagnostic log** opens `~/Library/Logs/Gatekeeper/gatekeeper.log`. It records operational events and fixed error categories, without goals, screenshot contents, account emails, tokens or model explanations. Each line has a millisecond UTC timestamp and a per-launch `run` ID. Correlated `trace` IDs and monotonic `elapsed_ms` follow session start or detected app/Space/window/view changes through queueing, capture, local cache lookup, AI setup/reply, freshness validation, blur presentation and fade completion. Queue events include in-flight/connection flags and remaining scheduler cooldown; cache events include hit counts and whether motion comparison was needed. Cancelled, superseded, skipped and failed checks have distinct outcomes. Display IDs identify the affected monitor without logging window titles or their hashes. Local probes that find no change stay quiet. These timings start when the app detects a change, not at the physical gesture; inference is only one part of that interval.

File writes run serially off the UI thread. The active log rotates at about 2 MB with two archives (`gatekeeper.log.1` and `.2`), with owner-only file permissions. For a slow blur, find `scene_detected` (or `session_started`), follow its `trace`, and compare `ai_started`, `ai_reply_received`, `blur_presented` and `blur_fade_completed`. Cache recalls use the same trace and can bypass AI. System Console also receives operational events; file rotation applies only to these app-owned files.

Codex owns authentication and may maintain its own operational logs; ephemeral threads do not imply zero provider retention. No Gatekeeper backend or telemetry is included.

## Verification

```sh
swift build
swift test
swift run SmokeCheck
# Live vision requests using synthetic images, never desktop captures:
swift run SmokeCheck --analyse-fixture
swift run SmokeCheck --settings-fixture
swift run SmokeCheck --multi-screen-fixture
swift run SmokeCheck --task-brief-fixture
swift run SmokeCheck --conversation-fixture --model gpt-6-luna
swift run SmokeCheck --focus-ui-fixture --model gpt-6-luna
swift run SmokeCheck --interrupt-fixture --model gpt-6-luna
swift run SmokeCheck --supporting-work-fixture --model gpt-6-luna
```

Unit tests cover grayscale fingerprints, image changes across displays, accumulated changes, app-switch settling, cooldowns, error backoff, queued events during inference, timed session expiry, pause/resume, non-overlapping requests, late-result rejection, temporary-file cleanup, persisted summaries, interrupted-session recovery and abandoned sign-in recovery. Intervention tests additionally cover physical screen targeting, structured verdict validation, stale results, moving-content tolerance, scoped correction expiry, return/break actions, overlay removal on lifecycle changes, native panel ordering and click-through behavior. They use an injected clock, synthetic captures and a fake Codex connection; panel tests construct native windows without displaying them.

For a brief native panel smoke test (three seconds, no monitoring session or desktop upload):

```sh
open "dist/F Distractions.app" --args --overlay-smoke-test
```

The **Preview blur** button does the same three-second visual test on the monitor containing Gatekeeper’s window, with a faster preview fade. It works before or during a session and restores real interventions afterwards. The test displays one blur/card pair, clears it automatically, and records visible/remaining panel counts in the diagnostic log. Quit an already-running Gatekeeper first so launch arguments reach the new instance.

The classifier uses structured output and read-only ephemeral Codex threads, with shell execution, apps/plugins/hooks, browser/computer use, multi-agent work, image generation, skill search, web search and MCP servers disabled in its child process. Server-initiated tool requests are rejected. Screenshot content is untrusted evidence. This is a POC, not an unbypassable blocker.

## Signing

The build script selects the first Apple Development signing identity. Pin a consistent one with `GATEKEEPER_SIGNING_IDENTITY`. It rejects ad-hoc signatures and refuses to replace a running app. A stable certificate-based designated requirement keeps macOS permission grants consistent across builds.

Old ad-hoc builds left stale permission records. Only when migrating from those builds: quit Gatekeeper, run `tccutil reset ScreenCapture dev.gatekeeper.poc`, open the signed build and approve it once. Do not reset permissions for other apps. Normal rebuilds with the same identity do not require a reset. Public distribution needs appropriate signing/notarization and confirmation of commercial subscription integration eligibility.

For the local capture-filter integration check, quit the app and launch:

```sh
open "dist/F Distractions.app" --args --capture-filter-smoke-test
```

This briefly shows synthetic blue/red windows, captures locally and checks that the blue normal window is included while the red overlay is excluded. It deletes all capture files and does not send an AI request. The diagnostic log records pass/fail.
