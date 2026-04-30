# Firebase Boot Status Page

This folder contains a static dashboard to show per-device OTA acknowledgements from Firebase Realtime Database.

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

- Device write (per device):
  - `https://techlora-369-default-rtdb.asia-southeast1.firebasedatabase.app/boot_ack/<device_id>.json`
- Dashboard read (all devices):
  - `https://techlora-369-default-rtdb.asia-southeast1.firebasedatabase.app/boot_ack.json`

Device naming convention is `project-node` (example: `spm-001`). The dashboard filters by the `project` prefix.

## Required DB rule for minimal setup

For quick testing, allow read on the collection and write on each device key. Example:

```json
{
  "rules": {
    "boot_ack": {
      ".read": true,
      "$device": {
        ".write": true,
        ".validate": "newData.hasChildren(['device_id']) && newData.child('device_id').val() == $device"
      }
    }
  }
}
```

After validating, tighten rules.

## What gets shown

- All keys in each device payload are rendered dynamically.
