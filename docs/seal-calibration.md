# Pressure seal colors

This update connects the existing three-sector pressure seal model to measured calibration in Settings. It retains the approved camera layout. It does **not** fix the separately observed all-sensor stuck-busy fault, add pump control, or connect MCAP trial recording.

## Build and install

Upload `suction-umi-v2-seal-colors.bundle` to the Codespaces repository root:

```bash
git bundle verify ./suction-umi-v2-seal-colors.bundle &&
git fetch ./suction-umi-v2-seal-colors.bundle usi-v2/seal-calibration &&
git merge --ff-only FETCH_HEAD &&
git push origin main
```

Run **Suction UMI v2 iOS build** on `main`, leaving simulator checks unchecked. Download `suction-umi-v2-seal-colors-<run ID>` and install `Suction-UMI-v2-seal-colors.ipa` through iLoader. Build versions start with `5.`. The app identifier is unchanged.

## On the phone

First establish stable live readings. Open **Collect Demonstrations → Settings**:

1. Cups open, suction OFF: wait one second, then **Capture Open**.
2. All cups sealed against a flat surface, suction ON: wait for steady readings, then **Capture Sealed**.
3. Tap **Use calibration**, then **Save and Done**.

Only the user operates the pump. Calibration buttons read measurements and never actuate hardware. A failed capture or rejected calibration leaves the saved calibration unchanged. Capturing a new Open baseline clears the previous Sealed draft. Clear seal calibration returns the sectors to gray without hiding valid numeric pressures.

Green means the channel meets the measured pressure-seal threshold; red means valid pressure without that seal; gray means unknown, uncalibrated, invalid, or stale. All three green produces “Full pressure seal · 3/3.” This is a two-point pressure preview, not measured holding force. Validate it against partial seals, leaks, and the actual object before using it as a trial label.

C1/C2/C3 label sensor channels 0/5/6. Verify the numbered chamber assignment one cup at a time. The sectors refer to those numbered channels; no unmeasured physical angular mapping is inferred.

## Measurement rules

- A bounded window retains at most 200 original decoded pressure samples. Capture uses the last second, requires at least 30 valid triples spanning 500 ms, a valid latest measurement no more than 200 ms old, no gap over 100 ms between accepted triples, and at most 2 kPa spread per channel. The reference is the median per channel.
- Each sealed reference must be at least 5 kPa lower than the corresponding Open reference. Wrong-direction, nonfinite, or missing values are rejected.
- Green turns on at 70% of the measured open-to-sealed pressure drop. Red returns below 50% of that vacuum drop. A state change must persist for 200 ms. Settings displays the actual absolute-kPa thresholds.
- Raw pressures are retained unchanged. Invalid or stale readings cannot become green. The saved calibration survives Bluetooth reconnect and app restart; old live readings do not. Recalibrate after changing the rig, cups, tubing, or numbered sensor assignment.
- Settings persists the measured references and calibration ID on the phone. Corrupt or invalid saved profiles load as uncalibrated. Recording/export of calibration metadata remains part of the pending native recorder integration.

## Evidence and current hardware issue

The four new Foundation tests first failed because calibration/profile integration was missing, then passed after implementation. All 71 Foundation tests pass. UIKit source syntax parsing and whitespace checks pass on Ubuntu; a native iOS SDK build and physical color verification still require the cloud build and phone.

On the current rig, a full power cycle restored all three sensor readings and a 15-second BLE capture delivered 2165 pressure samples at 144.27/s with no source sequence gaps or discarded fragments. C1/C2 were valid throughout; C3 had three invalid samples. User then reported all three readings disappearing after sustained pump operation, possibly following contact with the apparatus. USB diagnostics again found all sensors returning persistent status `0x60` and failing new measurement requests. Pump and sensor electronics have separate supplies. The initiating cause remains unresolved; no software fix is claimed. The next hardware comparison is one minute untouched with the pump OFF after a full sensor power cycle.
