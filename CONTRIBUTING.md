# Working together

Use the same GitHub repository with a separate local clone on each machine. Codex and Claude edit ordinary source files; neither developer needs to switch coding assistants.

## First setup

```sh
git clone https://github.com/DFly7/f-distractions.git
cd f-distractions
```

Read [the product rules](docs/behaviour.md) and [architecture](docs/architecture.md). On Mac, follow [apps/mac/README.md](apps/mac/README.md). Windows implementation and tooling are left to the Windows contributor. There is nothing Mac-specific to install just to read shared docs or propose changes to them.

The owner can invite the other developer through GitHub Settings → Collaborators for write access. Public read access is already available; contributors without write access can fork and open a pull request.

## Each change

Start with a current main and a short feature branch (the branch name below is an example):

```sh
git switch main
git pull --ff-only
git switch -c mac/improve-session-controls
```

Make a focused change, inspect `git diff`, run the relevant checks, then commit and push your branch:

```sh
git add <files-you-changed>
git commit -m "Describe the resulting change"
git push -u origin HEAD
```

Open a pull request on GitHub. Ask the other developer to review shared behaviour or contracts; merge when the relevant checks pass. Pull main before starting the next change. Use branches per feature, rather than permanent Mac and Windows branches, so both platforms remain together on main.

Avoid editing the same files at once. Put platform changes under the platform app and use an issue or draft PR to agree on changes to shared behaviour. If both developers change a contract, resolve that agreement before merging; separate branches alone do not prevent semantic conflicts.

## Expectations for a pull request

Explain the user-visible change, platform affected and verification performed. If a shared rule changes, update docs/behaviour.md and matching scenarios or schemas in the same PR. Label proposed behaviour separately from implemented behaviour. A Windows implementation should document its own build/test commands when it lands.

The common coding-agent instructions are AGENTS.md. CLAUDE.md imports that file. Keep personal agent settings and credentials local.

## Verification

Mac changes: run `swift build` and `swift test` from apps/mac/. The `Mac checks` GitHub Actions workflow repeats those checks without a sign-in or certificate. Signed packaging and live AI smoke checks remain local; see the Mac guide. Windows CI can be added by its contributor with the implementation. Passing Mac tests does not establish Windows support.

Shared fixtures contain synthetic examples, never screenshots of personal activity. The contracts are documented in shared/README.md; JSON Schema validation alone does not establish index completeness or aggregate verdict correctness.
