# AI analysis and screen handling handoff

For James and his agent. Updated 16 November 2026. This describes the implemented **Mac** app through commit `113695a`; it does not establish Windows parity. Read [behaviour.md](behaviour.md), [architecture.md](architecture.md) and [shared contracts](../shared/README.md) before adapting it. Windows framework, capture integration and build setup remain owned by the Windows contributor.

## What changed

- **Two analysis slots:** two independent persistent local Codex app-server connections, warmed after subscription sign-in. The selected model is passed to both; supported models use low reasoning effort. Threads are fresh and ephemeral per call; thread reuse is not implemented.
- **Priority work overlaps:** initial/background requests assess all screens. App/Space/window/view changes can use a free slot after 350 ms and local comparison, without waiting for the other request or ordinary three-second request floor. Both slots busy means one newest pending view, captured when a slot frees. Background gap and failure backoff remain.
- **Only changed screens uploaded for priority checks:** capture all connected displays locally, then select changed, non-approved, non-cached views. Any capture failure fails the batch. Matching stable content prevents title counters or moving video from duplicating inference.
- **Per-display ordering:** each submitted view owns a request generation for its physical display. Older replies cannot overwrite a newer assessment or initiate blur for that display. They may update unaffected monitors. Results/previews merge by physical display and retain individual capture timestamps. Request-local screen index 1 may refer to physical Screen 2: never use it directly for targeting.
- **Freshness without cancellation starvation:** title changes no longer repeatedly cancel ongoing classification. Before adding blur, validate the physical display, window identity, result age (20 seconds maximum), and fresh content as appropriate. Changed tabs must not inherit old verdicts. The ordinary policy's settling is bounded to one second per burst.
- **Scrolling fix:** recent scroll metadata in the same known window/title can distinguish ongoing scrolling from navigation. A hint lasts up to 1.5 seconds, requires no click or metadata navigation since capture, and cannot itself create an off-task verdict. Click/window/title changes invalidate it. Unknown identity falls back to conservative image checks. This prevents continued scrolling from repeatedly withholding a genuine off-task result. No keyboard events or typed content are monitored.
- **Local recall:** up to 40 confirmed off-task views for ten minutes within the session, matched by physical display, window/process/title identity and stable pixels. A follow-up local frame can ignore video motion. Relevance corrections remove matching cached false positives.
- **Capture includes the focus app:** normal F Distractions windows/dialogs are visible evidence. Only blur/card panels, including retiring panels, are excluded. Images are JPEG, longest side up to 1600 px, quality 0.8; local fingerprints are 160×90 grayscale.

## Invariants to preserve

1. Blur is per physical display and **latched**. On-task/unsure results, errors and changed content cannot dismiss it.
2. Return to work clears only the clicked screen, with a three-second navigation window. Existing in-flight results cannot undo that grace period.
3. This is relevant is scoped to the view, up to two minutes; changed content/window/title ends it. It is not a permanent app allowlist.
4. Early pause/end/new task/quit require the existing ten-second continuous hold. Lifecycle cleanup and expiry remain automatic.
5. Keep completed assessments visible during refresh; local comparisons do not cause loading flashes.
6. Pause/end/expiry/shutdown stop both workers, drop late replies and clean temporary images. Relaunch never resumes monitoring automatically.
7. Screenshot text is untrusted evidence. Classification tools stay disabled. Only validated `off_task` with `active_content` evidence can start blur; inactive sidebar labels and historical previews cannot.

## Where to look

| Area | Source |
| --- | --- |
| Scheduling, two slots, generations, merged results, scrolling hints | [AppModel.swift](../apps/mac/Sources/Gatekeeper/AppModel.swift) |
| Capture, window identity, overlay exclusion | [ScreenCapture.swift](../apps/mac/Sources/Gatekeeper/ScreenCapture.swift) |
| Local fingerprints and ordinary request policy | [ScreenComparison.swift](../apps/mac/Sources/GatekeeperCore/ScreenComparison.swift) |
| Freshness, cache, scoped approvals | [InterventionRules.swift](../apps/mac/Sources/GatekeeperCore/InterventionRules.swift) |
| Subscription connection, structured responses, validation, disabled tools | [CodexClient.swift](../apps/mac/Sources/GatekeeperCore/CodexClient.swift) |
| Runtime classifier instructions | [FocusClassifierPrompt.swift](../apps/mac/Sources/GatekeeperCore/FocusClassifierPrompt.swift) |
| Reference prompts, schemas, synthetic scenarios | [shared/](../shared/README.md) |
| Native per-screen blur and fade timings | [FocusOverlayController.swift](../apps/mac/Sources/Gatekeeper/FocusOverlayController.swift) |
| Timing logs and rotation | [Diagnostics.swift](../apps/mac/Sources/Gatekeeper/Diagnostics.swift) |
| Overlap/order/lifecycle/scroll regression checks | [ParallelAnalysisTests.swift](../apps/mac/Tests/GatekeeperTests/ParallelAnalysisTests.swift) |

Shared prompts/schemas document the Mac implementation; they are not loaded by the app. Keep embedded source, references and fixtures aligned. Agree behaviour changes before porting to another platform. The proposed stronger Return-to-work navigation and stricter relevance-confirmation ideas from conversation are **not implemented**.

## Measuring latency

Use Settings → Open diagnostic log. Mac path: `~/Library/Logs/Gatekeeper/gatekeeper.log`. UTC timestamps include milliseconds; per-launch `run` and per-change `trace` IDs connect detection → queue → capture/cache → provider → freshness → blur presentation/fade. `ai_started` includes slot, sequence, concurrent count and physical display IDs. `parallel_pending` means both workers were occupied; `assessment_discarded` identifies obsolete responses; `blur_withheld` explains freshness rejection. Compare detection to `blur_presented`, not just provider duration.

Writes are serial and off the UI thread. The active log rotates at about 2 MB with two archives. Operational logs exclude screenshots, task text, account details, window titles and model explanations. Do not commit personal logs or sessions. Detection timing starts at the app event/probe, not the user's physical gesture.

## Actual verification and limits

At `113695a`, `swift build` and `swift test` passed on Mac: **86 tests**, including concurrent starts, out-of-order replies, newest pending view, changed-screen-only upload, physical-screen mapping, pause/expiry cleanup, scrolling and hint expiry. Earlier native capture smoke verification checked normal app inclusion and overlay exclusion.

A local subscription smoke check with **two generated images**, not a desktop capture, confirmed overlapping independent Luna requests and valid on-task/off-task outputs. One run completed both in 5.3 seconds wall time; this is a sample, not a latency guarantee. It does not verify real Safari Maps behaviour end to end. Run manually, never in CI:

```sh
cd apps/mac
swift build
swift test
swift run SmokeCheck --parallel-fixture --model gpt-6-luna
```

Remaining: measure real switch-to-blur latency from the new traces, retest continued scrolling and desktop navigation on multiple displays, and investigate any duplicate calls, stale-result rejections or provider contention. Scroll/click and pixel heuristics are not semantic navigation proof; missing events/metadata remain conservative. Overlap can increase subscription usage and does not remove model inference time. Windows has not been built or tested here.

## Relevant commits

- `113695a`: overlapping checks, changed-display uploads, generations, scrolling fix, prompt/reference updates and regression tests.
- `0534c2c`: prevent title/metadata churn from starving first decisions; per-screen freshness.
- `f79b996`: correlated bounded operational timing logs.
- `c0faa63`: desktop-change cache recall and moving-content matching.
- `78cc377`: immediate session start and recognition of task-supporting work.
