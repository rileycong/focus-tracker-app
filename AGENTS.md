# AGENTS.md

## Backlog and workflow
- Canonical backlog: GitHub issues on this repo (`gh issue list -R rileycong/focus-tracker-app`). Never create local task files; `_docs/tasks.md` was deleted deliberately.
- Follow `_docs/process.md`: issue is groomed → implemented → verified → closed only after a passing verification run. One session = one issue.
- Push directly to `main` (no PR flow). Reference the issue in the commit message, e.g. `Scaffold ... (#3)`.
- Product contract is the PRD `_docs/plan.md`; each issue cites the PRD sections it needs. Out of scope per user decision: Lifebot, health data, PRD §22 criteria 23–25.

## Build and test
- `FocusTracker.xcodeproj` is generated from `project.yml`. Edit `project.yml`, run `xcodegen generate`, then build. Never hand-edit the `.xcodeproj`.
- Test: `xcodebuild -project FocusTracker.xcodeproj -scheme FocusTracker -destination 'platform=macOS' test`
- Build: same command with `build`. A green test run is required before closing an issue.

## Toolchain quirks
- Signing is intentionally ad-hoc (`CODE_SIGN_IDENTITY: "-"`, no DEVELOPMENT_TEAM). Do not "fix" it by adding a team.
- Fresh machine: `sudo xcodebuild -license accept` then `xcodebuild -runFirstLaunch`; until then git/brew/python3 all fail with license errors (observed on this machine).
- Only dependency is Yams (SPM) for YAML frontmatter. Keep it that way (PRD §23: simplest reliable solution, no unneeded deps).

## Data rules
- The app reads/writes exactly two vault folders: `Tasks/` (one Markdown file per top-level task, YAML frontmatter, nested subtasks inside the parent file) and `Logs/YYYY-MM-DD.md` (sessions + breaks). Never touch other vault content.
- Vault path is user-configurable; `fixtures/sample-vault/` (issue #2) is the canonical schema reference for tests and formats.
- Data integrity is non-negotiable (PRD §18): UUIDs, atomic writes (temp file in same dir → rename), rename-safe references by ID not title, no silent data loss.