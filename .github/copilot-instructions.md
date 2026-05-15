```instructions
# Copilot instructions — Dosamatic stepper-caliberation

Purpose: Give AI coding agents the focused, actionable knowledge needed to make safe, small, and correct changes across the Flutter UI (`dosamatic_app`) and the ESP32 firmware (`stepper-caliberation`).

Repository scope
- Firmware source of truth: `stepper-caliberation/stepper-caliberation.ino`.
- UI client: `dosamatic_app/` (Flutter). The single-screen controller lives in `dosamatic_app/lib/main.dart`.
- API contract reference: `api-docs.yaml` (use for quick lookup, but verify against the firmware code).

Big-picture architecture (quick)
- Device (ESP32) exposes a small REST API (`/api/*`) implemented in the `.ino` file; it controls steppers, homing, limits and reports status.
- UI polls device status on an interval and issues command POSTs (path/home/stop/limits). See `_fetchStatus()` and POST handlers in `dosamatic_app/lib/main.dart`.
- Firmware enforces limits and request validation (clamping, non-negative positions, MAX_WAYPOINTS); client should mirror those checks if adding optimistic updates.

Key files to inspect for behavior and examples
- Firmware handlers and constants: `stepper-caliberation/stepper-caliberation.ino` (search for `GET /api/status`, `POST /api/path`, `MAX_WAYPOINTS`).
- UI polling and commands: `dosamatic_app/lib/main.dart` (`_fetchStatus()`, `_sendPath()`, `_home()`).
- API spec: `api-docs.yaml` (compare but trust firmware code when discrepancies appear).

Project-specific conventions and patterns
- HTTP field names are literal and stable: `x`, `y`, `z`, `max1`, `max2`, `max3`, `m1_pos` etc. Do not rename keys in one component without updating the other.
- Minimal, in-file state management in Flutter: avoid introducing large external state frameworks unless you update both app and firmware together.
- Polling is used (1.5s interval in current app). Changing to push/WS requires simultaneous firmware changes.
- Conservative changes only: the repo is an MVP — prefer small, verifiable edits over broad refactors.

Build / run / debug workflows (concrete commands)
- Flutter app (from `dosamatic_app`):
  - `flutter pub get`
  - `flutter run` (choose device)
  - `flutter analyze`
  - `flutter test` (note: `test/widget_test.dart` is template-generated and may need fixes)
- Firmware: use Arduino/ESP32 toolchain (Arduino IDE, PlatformIO, or ESP32 CLI). Libraries used include `AccelStepper`, `ArduinoJson`, `WebServer`, `ArduinoOTA`, `ESPmDNS` — verify in `libraries/` and `build/` output.

Integration notes and gotchas
- Default UI target host is mDNS: `dosamatic.local` (defined in `lib/main.dart`). If mDNS fails, use direct LAN IP.
- Firmware sets and enforces per-axis limits; client-side clamping should mirror firmware logic to avoid rejected requests.
- Homing sequence includes a WAITING state (~5s) before `READY` — do not send movement commands during that window.
- CORS: firmware enables `/api/*` for web builds — browser-based testing should work when device and host are on same LAN.

When modifying endpoints or payloads
- Update both `stepper-caliberation/stepper-caliberation.ino` and `dosamatic_app/lib/main.dart` together.
- Update `api-docs.yaml` only as a reflection of code changes, not the other way around.

Search tips for quick context
- To find REST handlers in firmware search for `on("/api/` or `server.on("/api/` inside the `.ino` file.
- To find UI callers search for `POST /api/` or `_sendPath` in `dosamatic_app`.

If you need to change architecture
- Propose explicit, minimal API extensions (new endpoint + backward-compatible fields) and update both sides.

Questions or missing pieces
- If you want CI commands, test matrices, or PlatformIO configs added, ask and include the target environments/devices.

``` 