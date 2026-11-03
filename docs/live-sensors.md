# Suction UMI v2 — live sensor connection

This increment retains the approved camera layout and wires real CoreBluetooth telemetry into its pressure and suction readouts. It does not connect trial recording yet. The saved collection protocol/runtime/host sources are included for subsequent integration; their presence does not mean the app runs the v2 recorder.

## Phone behavior

- Collect Demonstrations scans for the documented USI BLE service, connects, discovers telemetry/clock characteristics, and requires a successful notification subscription.
- Allow the Bluetooth permission when iOS asks. A status line below Suction describes scanning, connection, permission, or retry state.
- C1/C2/C3 show fresh, valid absolute kPa from source channels 0/5/6. This is the sensor-channel order; physical chamber placement still needs calibration.
- The displayed suction state is derived from the trigger: pressed = OFF, released = ON. It is read-only and does not measure the pump or command a motor.
- Pressure expires after 250 ms, trigger after one second. Disconnection clears both. Duplicate/out-of-order samples cannot keep an old reading fresh. One bounded display snapshot is scheduled at most every 100 ms.
- Seal sectors remain gray until numeric pressure calibration is implemented and measured. A saved calibration *label* is not a threshold calibration.
- Data reports per-connection decoded sample counts, observed sequence gaps, duplicates, rejected packets, and the sensor freshness limits. These are phone reception counters, not source acquisition or MCAP counts.
- Opening Data or Settings keeps capture and BLE running. Leaving collection or backgrounding stops both; returning reconnects with fresh display state.

## Source and install handoff

The bundle is based on the published camera-layout commit `c3371c6` and exposes branch `usi-v2/live-sensors`. Upload `suction-umi-v2-live-sensors.bundle` into the Codespaces repository root, then:

```bash
git bundle verify ./suction-umi-v2-live-sensors.bundle &&
git fetch ./suction-umi-v2-live-sensors.bundle usi-v2/live-sensors &&
git merge --ff-only FETCH_HEAD &&
git push origin main
```

Run **Suction UMI v2 iOS build** on `main`, leaving simulator checks unchecked for the quick build. Download `suction-umi-v2-live-sensors-<run ID>`, extract **Suction-UMI-v2-live-sensors.ipa**, and install through iLoader. The separate app identifier is unchanged.

The ESP32 needs the prepared private BLE firmware, not the previous Wi-Fi-only sketch. Firmware source/binary and any board backup stay outside this public repository. Replacing the installed ESP32 program is a separate physical update, with a backup first. No board update is performed by this build workflow.

## Validation and next steps

Linux Foundation tests cover pressure units, stale/invalid data, trigger independence, duplicate/gap handling, boot changes, and reconnect reset. The native CoreBluetooth adapter is syntax-checked on Linux; native SDK compilation runs in GitHub Actions. Actual radio reception remains unverified until the app and firmware run together on the phone/rig.

Next physical check: with BLE firmware installed and Bluetooth allowed, confirm all three readings update and the real trigger changes the suction display. Then measure chamber calibration and finish v2 USB sensor/pose forwarding and host-acknowledged MCAP Start/Stop. Start still explains that recording is pending; it never claims an unsaved trial is recording or Saved.
