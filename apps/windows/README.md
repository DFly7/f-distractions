# F Distractions for Windows

Status: **early prototype.** It runs locally on Windows 10 2004+ / Windows 11. It has no installer and no signed release. Passing Mac checks says nothing about this app, and vice versa.

The product rules are in [docs/behaviour.md](../../docs/behaviour.md). This app is a native C#/WPF implementation of the same rules; it does not share code with apps/mac/.

## What works today vs. what's planned

| Area | Status on Windows |
|---|---|
| Capture every connected monitor (per-monitor DPI aware, ordered left→right) | Implemented. Fails the whole check if any monitor fails. |
| Capture the main window like any app, but keep blur/card overlays (including fading ones) out of screenshots | Implemented: overlays use `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`. Needs manual verification on each machine (see below). |
| Screenshots stay in memory, downscaled to ≤1600 px JPEG | Implemented. Nothing is written to disk. |
| Validate assessments (exact screen indices, statuses, `evidenceSource`, off_task only with `active_content`, aggregate) | Implemented and tested against `shared/fixtures/verdicts.json`. |
| Assess screens with Claude through the user's own Claude Code sign-in | Implemented (see [AI connection](#ai-connection)). Unit tested with a fake Claude Code process; live checks need manual verification. |
| Test classifier (no AI, never inspects pixels, sends nothing) | Implemented, for testing overlays without using your plan. |
| Model choice | Claude Code default, Opus, Sonnet or Haiku aliases. |
| Per-screen click-through blur that grows in from the edges over 1.4 s | Implemented. The blur is a blurred copy of the assessed screenshot, not a live blur of what's underneath. |
| Interactive card above the blur, never takes focus, Escape does nothing | Implemented. |
| Blur stays latched: later on-task/unsure/neutral results, errors and navigation can't clear it | Implemented and unit tested. |
| Return to work: clear only that screen over 450 ms, 3-second grace, then priority recheck | Implemented and unit tested (grace logic). |
| Freshness: don't start blur from results older than 20 s or after the display layout changed | Implemented. |
| Freshness by window/title identity and pixel fingerprints | Planned. |
| Local cache of recently confirmed off-task views (reblur without AI) | Planned. |
| This is relevant (two-minute view exception) | Planned. |
| Take a break from the card | Planned. |
| 10-second continuous hold for Pause and End (mouse or Space; release/drag-out/switch away resets) | Implemented in the main window. |
| 10-second hold for Quit / New task | Quit during a session sends you to the End hold first. New task: no separate flow yet. |
| Pause on sleep / Windows lock, explicit resume | Implemented. |
| Timer expiry completes the session | Implemented. |
| Disconnecting a monitor removes only its panels | Implemented; not yet tested with a real unplug. |
| System tray icon; closing the window keeps the app running | Implemented. |
| Windows CI (build + unit tests, no live AI) | Implemented: `.github/workflows/windows.yml`. |
| Task refinement, session history, settings, installer | Planned. |

## Setup (one time)

1. Install Git and the GitHub CLI, then sign in: `gh auth login`.
2. Install the .NET 10 SDK:
   ```powershell
   winget install --id Microsoft.DotNet.SDK.10 -e
   ```
3. Clone the repository and open a terminal in `apps/windows`.

4. For real assessments, install Claude Code with Anthropic's native Windows installer and sign in yourself:
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   claude auth login
   ```
   The app looks for `claude.exe` on PATH and in `%USERPROFILE%\.local\bin`. The npm (`claude.cmd`) install isn't supported yet.

An editor is optional. VS Code with the C# Dev Kit extension or Visual Studio 2026 Community both work.

## AI connection

Decision (Windows contributor, 2026-11-16): the Windows app assesses screens with **Claude via the user's own Claude Code install and sign-in**, mirroring how the Mac app uses the user's own Codex/ChatGPT sign-in. There is no API-key option for now.

How it works (`src/FDistractions.Core/ClaudeCodeClassifier.cs`):

- Runs the unmodified `claude.exe` as `claude -p` with `--input-format stream-json`, sending the goal and the JPEG screenshots on stdin. Nothing is written to disk.
- Uses the same instructions as the Mac app (`shared/prompts/classify.txt`, embedded at build time) and asks for the shared verdict format with `--json-schema`. The answer is still validated by `VerdictParser`. A failure is an error, never an off-task verdict.
- Tools are removed (`--tools ""`, `--disallowedTools "mcp__*"`, `--strict-mcp-config`, `--disable-slash-commands`, `--permission-mode dontAsk`). Runs start in an empty temp folder, so no project `CLAUDE.md` is loaded, and `--no-session-persistence` keeps them out of Claude Code's history. Your user-level `~/.claude` settings and memory still load, because subscription sign-in isn't available in `--bare` mode.
- The app checks sign-in only with `claude auth status` and reads only the `authMethod` field. It never reads, stores or handles Claude credentials.

Terms and risk, to revisit before sharing the app with anyone:

- Anthropic's [legal page](https://code.claude.com/docs/en/legal-and-compliance) allows an end user to sign in to the unmodified Claude Code binary with their own subscription. The same page says subscription limits assume ordinary individual use and that developers may not route their product's requests through users' Pro/Max credentials. The [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) says third parties need approval to offer claude.ai login or rate limits, "including agents built on the Claude Agent SDK", and `claude -p` is documented as the Agent SDK's CLI form.
- Using Claude Code as a periodic screenshot classifier is further from ordinary Claude Code use than a coding front-end such as T3 Code. We have not asked Anthropic. Treat this as personal use at the user's own account risk, and contact Anthropic before distributing the app.
- Each check sends screenshots of every monitor to Anthropic and counts towards the user's plan limits. At a 30-second gap that's up to 90 checks in a 45-minute session.

## Build, test, run

From `apps/windows`:

```powershell
dotnet build FDistractions.Windows.slnx
dotnet test FDistractions.Windows.slnx
dotnet run --project src/FDistractions.App
```

The unit tests need no screen, no sign-in and no AI. They read the synthetic fixtures in `shared/fixtures/`.

The `Windows checks` GitHub Actions workflow (`.github/workflows/windows.yml`) runs the same build and tests on GitHub's Windows machines whenever `apps/windows/` or `shared/` changes.

There is also one opt-in live test, which is skipped by default. It sends two **synthetic** images (never real screenshots) through your signed-in Claude Code and uses a little of your plan. Never enable it in CI. To run it, put `screen1.jpg` (an on-task page for "Write my history essay on the causes of the French Revolution") and `screen2.jpg` (an obviously unrelated page) in a folder outside the repo, then:

```powershell
$env:FDISTRACTIONS_LIVE_CLAUDE_IMAGES = 'C:\path\to\synthetic-images'
dotnet test tests/FDistractions.Core.Tests --filter "FullyQualifiedName~LiveClaudeCodeTests"
```

## Manual test: capture → assess → overlay → explicit dismissal

Do this on a real monitor setup. Use harmless content on screen: these tests don't save screenshots, but don't need personal content either.

1. Run the app. Check **Screens detected** lists every monitor with the right resolution and scaling.
2. Enter a goal, choose **Off task on the chosen screen, once**, pick a screen and start a short session (e.g. 5 minutes).
3. Within a second or two the chosen screen should blur in from the edges with a card on top. Other screens stay clear.
4. **Click-through:** click and scroll on the blurred screen. The app underneath should respond and the card should not steal focus.
5. **Latched:** switch tabs/windows on that screen and press **Check now** a few times (the test classifier now says on task). The blur must stay.
6. **Escape** does nothing to the card.
7. **Return to work:** the blur and card fade out over about half a second, only on that screen. The main window shows a priority check about 3 seconds later.
8. **Overlays excluded, main window included:** choose **Off task on the chosen screen, every check**, put the main F Distractions window on the target screen and start. The blurred image should show the F Distractions window, because it's captured like any other app. After Return to work and the reblur, the new blur must not contain the previous blur or card.
9. **Errors don't blur or unblur:** choose **Every check fails**; you should see an error and no blur.
10. **Hold:** hold **Hold to end session** for 9 seconds and release. Progress resets and the session continues. Hold for the full 10 seconds and the session ends and all blur clears. Repeat with Space after tabbing to the control. Switching to another window mid-hold resets it.
11. **Pause/lock:** lock Windows (Win+L) during a session. On return the session is paused, blur is gone and Resume is explicit.
12. **Tray:** close the main window; the app stays in the tray. Quit from the tray during a session sends you to the End hold.

13. **Claude check:** choose **Claude (your Claude Code sign-in)**. The status should say Claude Code is signed in. Start a session with a concrete goal and harmless on-task content, and confirm the latest check shows a verdict and reason for every screen. Then open clearly unrelated content (for example a cooking video) on one screen and press **Check now**: that screen should blur with Claude's reason on the card.
14. **Claude failures:** sign out (`claude auth logout`) and press **Check now**. You should see an error and no new blur, and any existing blur must stay.

Record what you tested, on which Windows version and monitor setup, in the pull request.

## Project layout

```text
FDistractions.Windows.slnx       Solution (open this in Visual Studio, or build with dotnet)
src/FDistractions.Core/          Platform-free rules: verdict validation, latched blur, hold, timing
src/FDistractions.App/           WPF app: capture, overlays, tray, main window
  Capture/                       Monitor enumeration and screenshots
  Overlays/                      Click-through blur window, interactive card, overlay manager
  Controls/HoldButton.cs         10-second continuous hold control
  Session/SessionController.cs   Scheduling, one-check-at-a-time, late-result rejection
  Interop/                       Win32 calls WPF doesn't expose
tests/FDistractions.Core.Tests/  xUnit tests, including the shared verdict fixtures
```

## Privacy

Screenshots are held in memory only and dropped after each check. With the Claude connection they are sent to Anthropic through Claude Code and processed under your Claude account's terms and retention settings. The test classifier never reads them and uploads nothing. No session history is saved yet. Never commit screenshots, captures, credentials or personal session data: `apps/windows/.gitignore` and the root `.gitignore` exclude common patterns, but check `git status` before committing.
