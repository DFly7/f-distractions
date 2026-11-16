# Architecture decision: one repo, native apps, shared contracts

Status: accepted for the current prototype, 2026-11-16.

The working Mac product uses SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics and native nonactivating overlay panels. Even the target named GatekeeperCore includes Apple graphics dependencies; its name does not mean it is a portable library.

Keep that working app in apps/mac/. Leave the Windows implementation and framework decision to its contributor. When ready, it can live in apps/windows/ on the same main branch. Each platform owns its capture permissions, display/window identity, overlays, tray/menu controls, storage paths, installer and signing.

Share the product specification, AI output schemas, prompt references and synthetic acceptance examples now. Initially, session scheduling and intervention policies may be implemented in both platform languages. This creates a risk of behaviour drifting; review changes against the shared scenarios and add platform tests for the same cases. Documentation is not an automated guarantee of parity.

This is the lowest-disruption starting point for two contributors working on different operating systems. It preserves the Mac prototype and avoids selecting a cross-platform runtime before the Windows developer has tested the hardest integration: capture → classify → overlay → explicit dismissal on a physical monitor.

## Boundaries

- **Native integration:** screenshot capture, including normal app windows while excluding intervention panels, stable display mapping, foreground window changes, click-through blur and actionable overlay cards.
- **Session policy:** explicit start/resume, frozen paused timer, request scheduling, in-flight cancellation, stale-result rejection, latched interventions and hold-to-exit.
- **AI adapter:** the Mac app currently uses CodexClient through GatekeeperConnection. Provider-independent verdicts and task briefs are documented in shared/. A coding assistant used to develop the project does not choose the app's runtime AI provider.
- **Local persistence:** existing Mac UserDefaults and Gatekeeper session history remain unchanged. There is no cross-device account, sync service or portable session-file guarantee.

The shared prompt and schema files are reference artifacts copied from the Mac source. They are not currently runtime resources. Keep them in sync when changing the source; avoid claiming the app uses an external prompt merely because a file exists.

## Revisit when there is evidence

After a Windows vertical slice works, compare the maintenance cost of duplicated policy and UI. Extract a genuinely portable core or consider a common UI only if it reduces measured ongoing work. A shared UI framework would still need native capture/overlay integrations. No framework migration, Windows dependency or shared-core runtime is introduced by this layout change.

## Repository migration

The old gatekeeper/ Swift package now lives at apps/mac/. Sources, tests and packaging scripts move together; the build script derives its package location from its own path. Commands and any local shortcuts that reference the old directory need the new path. The app's bundle ID, binary name, settings/history locations and signing logic remain the same. Build outputs and caches are ignored. The separate teacher/ concept remains reserved and has no implementation.
