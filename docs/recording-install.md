# Suction UMI v2 — first phone-to-MCAP trial

This source update includes the seal-color calibration update and connects the native app to the existing Core collection runtime/Ubuntu recorder. Native iOS compilation and the first physical trial remain validation gates; do not infer successful recording from the source or generated tests.

## Build the app

Upload `suction-umi-v2-recording.bundle` into Codespaces. It can fast-forward either the live-sensors revision `6ce4b5b` or the seal-calibration revision `5dc920a`:

```bash
git fetch ./suction-umi-v2-recording.bundle usi-v2/recording &&
git merge --ff-only FETCH_HEAD &&
git push origin main
```

Run **Suction UMI v2 iOS build** on `main`, leaving simulator layout checks unchecked. Download artifact `suction-umi-v2-recording-<run ID>` and install **Suction-UMI-v2-recording.ipa** through iLoader. Its build number starts with `6.`.

## Run the Ubuntu recorder

On this Ubuntu laptop, with the unlocked phone connected over USB:

```bash
cd /home/emi-linux/usi_ws/usi_v2/collection-worktree
bash scripts/run-collection-host.sh
```

The script uses the prepared Jazzy message overlay. Output goes to `~/usi_ws/recordings/suction-umi-v2`; an optional first argument selects another output directory. It connects through usbmuxd to the phone's port **5559**. Port 5558 remains the legacy camera diagnostic stream.

## On the phone

1. Open **Collect Demonstrations**. Wait for live camera/depth, all three pressures and a recorder connection. If Start reports missing data, read the listed reason and wait for the live lanes/clock observation to become ready.
2. For green/red sectors, use **Settings → Capture Open → Capture Sealed → Use calibration** as described in [seal-calibration.md](seal-calibration.md). Save settings before starting a trial. Without calibration, numeric pressures still record and sectors remain unknown.
3. Tap **Start trial**. “Preparing” means the clock/fence and host handshake is pending. “Recording” appears only after Ubuntu acknowledges actual writer acceptance.
4. For the first check, collect a short stationary trial, then tap **Stop**. Keep the phone unlocked, connected and in collection while “Finalizing” is displayed. “Saved · MCAP verified” requires a successful host close and independent reopen/verification. **Data** shows the actual saved path or the failure reason.

Core records RGB JPEG, raw LiDAR depth and confidence when provided by ARKit, independent camera pose/tracking, intrinsics, original three-channel pressure data and quality flags, trigger-derived suction, pressure seal classification, labels/calibration, timing exchanges and health metadata. Ultrawide is explicitly excluded. Camera pose is not a calibrated suction-tool TCP pose. Clock exchanges retain raw timestamps; no fitted synchronization is fabricated.

## Current limits and evidence

- The selected native ARKit format determines `target_fps`; the adapter requests the existing 60 FPS format when supported. Actual camera/image/pose cadence is verified by the host; a sustained-rate shortfall cannot be relabeled Saved. The JPEG queue is bounded by four runtime tickets and recording tickets are never coalesced.
- Start freezes settings and source identities. Stop closes admission, obtains source end fences and drains pre-end encoded work. Background, interruption, disconnect or failed end fencing cannot produce an invented complete trial. Reconnection queries an unresolved trial instead of silently resuming it.
- The host repair excludes out-of-fence images from trial-loss evidence and uses explicit source-prefix counters/identity coverage when pre-Begin encoder work makes lifetime totals ambiguous. A completed host now advertises readiness for the next trial.
- 73 Foundation tests and 116 Python/Jazzy tests passed locally, including generated MCAP readback and the new regression cases. These are software tests, not a physical trial. UIKit/Network source syntax parsing passed; native SDK build still runs in GitHub Actions.
- The separately observed all-sensor stuck-busy fault after pump/handling remains unresolved. A full sensor power cycle restored readings, and the user observed a stable pump-OFF minute with brief invalid-sample blips. Do not claim pump-on stress-test reliability. This update records quality flags and keeps invalid/stale sectors gray; it does not conceal the fault or actuate the pump.
