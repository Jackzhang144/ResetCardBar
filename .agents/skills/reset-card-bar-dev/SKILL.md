---
name: reset-card-bar-dev
description: Maintain ResetCardBar's native macOS menu bar UI, Codex reset-card polling, durable redemption recovery, and notifications. Use for implementation, debugging, testing, or packaging in this repository.
---

# ResetCardBar development

Work within this repository. Read its root `AGENTS.md` and the relevant source before changing behavior. Use `DEVELOPMENT.md` for commands and screenshot capture, and `docs/RELIABILITY.md` when touching redemption, reminders, or recovery. Resolve repository root with `git rev-parse --show-toplevel` rather than assuming a machine-specific directory.

## Choose the work path

- **UI:** keep rounded cards, a main panel without vertical scrolling, and a separate settings page. Paging affects display only. Use the existing `Dashboard`; validate the real running interface when layout changes. Screenshots must be actual app pixels, with the preview-window context disclosed.
- **Monitoring/recovery:** work through `src/Monitor.swift` and the serial queue in `src/main.swift`. Add targeted fake-service assertions in `tests/MonitorTests.swift` for changed failure paths. Transport changes use `tests/test_rpc.py` and the synthetic subprocess fixture.
- **Updates/releases:** read `docs/RELEASING.md`. Preserve the signing public key, incrementing build number, pinned dependency hashes, and safe restart during redemption. Use `src/Updates.swift` rather than a custom downloaded installer script. A published version is immutable.
- **Build/package:** use `make build`, `make test`, and `make package`. Version metadata lives in `resources/Info.plist`; generated output is `build/` or `dist/`. Packaging does not authorize installation, remote publishing, or live redemption testing.

## Preserve the recovery contract

Persist and synchronize the idempotency key before sending a consume request. Reuse it for uncertain outcomes, including after restart, card disappearance, or expiry. Mark success only for `reset` / `alreadyRedeemed`; keep success/outbox state even when the subsequent read fails. Isolate per-card failures, and stop the round after one confirmed successful reset.

Keep state isolated by account and fail conservatively on corrupt storage or absent account identity. Missing card details do not imply zero cards. Do not delete or overwrite the user's live ledger for tests.

Use fake services for ordinary consumption tests. `--check-account` and `--health-check` are read-only; `--preview` uses the real account and retains the current automatic-use setting. Keep prior user authorizations and preferences; do not change them merely to simplify a test.

Current default is 60 minutes before expiry, explicitly chosen by the user. Notification-icon troubleshooting was explicitly stopped; do not resume it during unrelated changes. Keep documented limits around lid sleep, shutdown, network loss, server eligibility, and app crashes.

## Finish

For code or script changes, run the relevant checks through `make test` and inspect failures. Check `git diff --check` and staged paths. Do not include account responses, runtime state, credentials, logs, or generated bundles in commits. Update the matching documentation when behavior or commands change, and report what was verified versus simulated.
