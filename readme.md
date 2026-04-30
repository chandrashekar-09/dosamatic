# Dosamatic Wireless Stepper Control System

This project contains a complete end-to-end solution for wirelessly controlling a 3-axis stepper motor system (with an additional DC motor) using an ESP32 microcontroller and a Flutter-based companion application.

## ⚙️ ESP32 Firmware (`stepper-calibration.ino`)

The hardware is powered by an ESP32 running an embedded HTTP Web Server. It uses a non-blocking state machine to manage motor movements seamlessly while still serving web requests and maintaining Wi-Fi connectivity.

### Capabilities & Features:
* **RESTful HTTP API**: Accepts incoming commands via standard HTTP JSON payloads.
* **Trajectory Queueing**: Receives an array of coordinates (waypoints) and executes them sequentially. This allows the system to draw complex, custom shapes without latency interruptions between points.
* **Over-The-Air (OTA) Updates**: Built-in `ArduinoOTA` support so the firmware can be flashed wirelessly.
* **Dynamic Motor Limits**: Physical max limits (e.g., maximum steps per axis) can be updated dynamically via the API to prevent hardware damage.
* **Homing Sequence**: Integrates with 3 limit switches (active low) to automatically home and zero out the X, Y, and Z axes upon request.
* **DC Motor Control**: Uses the ESP32's `ledc` PWM driver to control an MD13S DC motor driver.
* **mDNS Support**: Broadcasts as `dosamatic.local` on the network so you don't need to hunt for dynamic IP addresses.

### API Endpoints
_See `api-docs.yaml` for the complete OpenAPI 3.0 specification._
* `GET /api/status` - Reads the real-time position, limits, and current state (HOMING, READY, MOVING).
* `POST /api/path` - Submits an array of `[x, y, z]` coordinates to the movement queue.
* `POST /api/limits` - Sets the max reachable bounds for the stepper motors.
* `POST /api/home` - Triggers the automated homing sequence.
* `POST /api/stop` - Emergency stop. Freezes motors in place and flushes the movement queue.

---

## 📱 Flutter Application (`dosamatic_app`)

The companion app is built with Flutter, allowing it to run cross-platform (Mobile, Web, Desktop). It provides a sleek, real-time interface to interact with the ESP32 API.

### App Features:
* **Live Telemetry Dashboard**: Polls the ESP32 every 1.5 seconds to display the live state (`MOVING`, `READY`, `HOMING`), exact motor positions, and network connectivity status.
* **Manual Jogging**: Up/Down buttons for X, Y, and Z axes allowing you to nudge the motors by 1000 steps at a time. The app enforces limits locally before sending commands.
* **Preset Shapes**: One-click blueprint drawing. Includes "Square" and "Triangle" which calculate the necessary coordinate sequences and push the entire array to the ESP32 pathing queue.
* **Limits Configuration**: Allows the user to define and push physical boundary constraints to the machine directly from the UI.
* **Safety Controls**: Prominent "E-STOP" button to instantly halt all operations, alongside a remote "HOME" button.

## 🚀 Getting Started

**ESP32:**
1. Open `stepper-calibration.ino` in the Arduino IDE.
2. Ensure you have the `AccelStepper`, `ArduinoJson`, and standard ESP32 boards/libraries installed.
3. Update the Wi-Fi credentials (`ssid` and `password`).
4. Flash to the ESP32.

**Flutter App:**
1. Navigate to the `dosamatic/dosamatic_app` directory.
2. Connect your device (or use an emulator/web browser).
3. Run `flutter run`.
*(Note: If your device does not resolve `.local` domains, update the `_baseIP` variable in `lib/main.dart` with the ESP32's direct local IP address).*
