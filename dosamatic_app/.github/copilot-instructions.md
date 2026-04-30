# Copilot instructions for Dosamatic

## Repository scope
- This Flutter app (`dosamatic/dosamatic_app`) is the UI client for the ESP32 firmware in sibling folder `stepper-caliberation`.
- Treat `stepper-caliberation/stepper-caliberation.ino` as the backend source of truth for runtime behavior; `stepper-caliberation/api-docs.yaml` is helpful but less strict than code.

## Big-picture architecture
- UI and network logic are currently centralized in `lib/main.dart` (`ControllerPage` + `_ControllerPageState`).
- Data flow is polling-based: `_fetchStatus()` calls `GET /api/status` every 1.5s and updates `_deviceState`, positions, limits, and connectivity state.
- Control flow is command-style HTTP POSTs:
  - `POST /api/path` with `[{"x": int, "y": int, "z": int}, ...]`
  - `POST /api/home`, `POST /api/stop`, `POST /api/limits` with `{max1,max2,max3}`
- Firmware queues up to 50 waypoints (`MAX_WAYPOINTS`) and rejects path commands while state is `HOMING`, `WAITING`, or `MOVING`.

## Integration details that matter
- Default target host is mDNS: `_baseIP = 'dosamatic.local'` in `lib/main.dart`; if mDNS fails on device/network, switch to raw LAN IP.
- Firmware enforces non-negative axis positions and clamps by per-axis limits (`maxLimit1/2/3`), so client-side clamping should mirror that.
- CORS is enabled in firmware for `/api/*`, so web builds can call device directly.
- Homing includes a `WAITING` state with 5s delay before `READY`; avoid sending movement commands during that interval.

## Project-specific coding conventions
- Keep HTTP payload keys exactly as implemented (`x/y/z`, `max1/max2/max3`, `m1_pos` etc.); do not rename contract fields.
- Preserve the current lightweight style: no state-management framework is used; helper methods live inside `_ControllerPageState`.
- Keep interval-based polling unless you also update firmware and app contract together.
- Prefer minimal, targeted edits over broad refactors (the app is an MVP single-screen controller).

## Developer workflows
- Flutter app (from `dosamatic/dosamatic_app`):
  - `flutter pub get`
  - `flutter run` (choose platform)
  - `flutter analyze`
  - `flutter test` (note: `test/widget_test.dart` is default template and currently stale vs `DosamaticApp` class)
- Firmware (`stepper-caliberation/stepper-caliberation.ino`): developed via Arduino IDE/ESP32 toolchain, with `AccelStepper`, `ArduinoJson`, `WebServer`, `ArduinoOTA`, and `ESPmDNS`.

## Safe change boundaries
- If modifying endpoint behavior, update both:
  - `stepper-caliberation/stepper-caliberation.ino`
  - `lib/main.dart` call sites and parsing logic
- When adding new commands, mirror existing defensive patterns: firmware-side validation + client-side optimistic UI update followed by status poll reconciliation.
- Do not rely only on `api-docs.yaml`; verify final behavior in firmware handlers.
