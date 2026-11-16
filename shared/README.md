# Shared contracts and examples

These files let native implementations agree on product behaviour without selecting a common runtime or Windows framework.

- `schemas/verdict.schema.json`: AI assessment response, matching the current Mac fields.
- `schemas/task-brief.schema.json`: optional task-refinement response.
- `prompts/classify.txt` and `prompts/refine-task.txt`: reference copies of the instructions in apps/mac/Sources/GatekeeperCore/CodexClient.swift.
- `fixtures/verdicts.json`: synthetic valid/invalid payloads for response validators.
- `fixtures/behaviour-cases.json`: platform-neutral acceptance scenarios for future platform tests.

The Mac implementation currently embeds its schemas/prompts in Swift and does not load these files. Update both copies together when making a contract change. The scenarios are a reference checklist, not an executable cross-platform test suite.

## Verdict validation beyond the schema

Bind each request to its screenshot count N and its captured physical-display mapping. Require exactly N screen entries and the unique indices 1 through N (response order is not meaningful). The model-request schema additionally sets each index maximum and the array length to N. The static schema here cannot encode N.

Compute the aggregate status: any off_task → off_task; else any unsure → unsure; else any on_task → on_task; else unsure. Reject inconsistent responses. `neutral` is valid only on individual screens. Never use an unvalidated index to choose a physical display, and never turn malformed output into an off-task verdict.

The examples contain fake text, no real screen captures or personal session history. Implementations should use the same validation cases in their native test suites. Behaviour changes require agreeing the contract and updating docs plus fixtures in the same PR.

## What is not standardised yet

There is no shared on-disk session format or network API. The Mac's existing local session JSON and UserDefaults remain implementation details; a Windows app need not imitate Apple paths or Swift's date encoding. Define a versioned exchange format only when a real interoperability feature needs one.
