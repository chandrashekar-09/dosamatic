# Firebase Boot Status Page

This folder contains a minimal static website to show one-time ESP32 boot acknowledgement from Firebase Realtime Database.

## Deploy to existing site (techlora.web.app)

1. Install Firebase CLI (once):
   - `npm install -g firebase-tools`
2. Login:
   - `firebase login`
3. Deploy from this folder:
   - `cd firebase-boot-status`
   - `firebase deploy --only hosting`

If your Firebase project ID is not `techlora`, update `.firebaserc`.

## Realtime Database path used

- `https://techlora-369-default-rtdb.asia-southeast1.firebasedatabase.app/dosamatic/boot_ack.json`

## Required DB rule for minimal setup

For quick testing, allow read/write on this path only. Example:

```json
{
  "rules": {
    "dosamatic": {
      "boot_ack": {
        ".read": true,
        ".write": true
      }
    }
  }
}
```

After validating, tighten rules.

## What gets shown

- Device ID
- Firmware version
- Local IP
- SSID
- RSSI
- Boot uptime ms
- System state
- G-code mode
