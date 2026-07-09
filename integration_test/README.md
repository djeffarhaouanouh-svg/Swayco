# Integration tests

End-to-end tests that drive the **real app** (`main()`) on an emulator or
device. This is the right tool for a Flutter app — Playwright/Selenium can't be
used because Flutter renders to a `<canvas>` (no DOM to query).

## Run everything

```powershell
# Start an emulator (once):
flutter emulators --launch Pixel_9

# Run the whole suite (keys are read from .env automatically):
.\test-all.ps1 -Device emulator-5554

# Include the authenticated-navigation suite (needs a test account):
.\test-all.ps1 -Device emulator-5554 -Email you@example.com -Password yourpassword
```

Why the script: the app reads its config **only from `--dart-define`**, not from
`.env` at runtime (see `lib/config/app_config.dart`). `test-all.ps1` bridges the
gap by forwarding every `.env` key as a `--dart-define`.

## What's covered

| File | Needs account? | Checks |
|------|:--:|--------|
| `app_boot_test.dart` | no | App boots and renders a frame with no crash / black screen. |
| `login_test.dart` | no | Email/password fields render; invalid email + short password show validation errors; sign-in ⇄ sign-up toggle. |
| `authenticated_flows_test.dart` | **yes** | Logs in once, then every bottom-nav tab (Chat, Discover, Demandes, Profil) **+ the Settings screen + the Paywall sheet** mount without throwing. **Skips** (does not fail) when `TEST_EMAIL`/`TEST_PASSWORD` are absent. |

## Not covered yet

- **1:1 call + live translation** — needs two peers and microphone access, so
  it can't be a single-instance integration test. Best tested with a second
  device/account or a dedicated harness.
- **Deeper content checks** — opening a specific profile, sending a real
  message, swiping the Discover deck. The current authenticated suite asserts
  each screen *mounts*; per-action content assertions can be layered on top.

## Gotchas

- Never `pumpAndSettle()` here — the Lottie splash animates forever and it would
  spin. Use the fixed-frame `bootApp()` / `pumpUntilFound()` helpers in
  `helpers/boot.dart`.
- `await app.main()` must be timeout-bounded (the helper does this) or the test
  hangs to the 12-minute default timeout.
- Windows desktop is **not** a valid target (mobile-only plugins don't build);
  use an Android emulator/device, or Chrome via `test_driver/` + chromedriver.
