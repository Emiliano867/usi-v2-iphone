# Suction UMI v2: G3 build, install and validate

The custom app is named **Suction UMI v2**, with bundle identifier **com.emiliano867.suctionumiv2**, separate from stock **com.real.iphumi**. This allows both apps to remain installed. Its primary **Live USB Stream** entry opens the custom USI stream; inherited Collect Demonstrations and Deployment Mode remain available. The new mode uses one public-API ARKit session, raw camera pose/source timestamps, JPEG RGB and available raw depth/confidence. It does not yet implement BLE pressure, ROS publishing, MCAP, a calibrated suction TCP or calibrated clock mappings.

## Current verification

The Python protocol/usbmux/receiver tests pass locally (33 tests). This includes fragmented framing, bounded lengths, nonfinite/deep JSON, EOF/timeouts, reserved-field collisions, reconnect/session gaps and raw clock provenance. The new direct usbmuxd connector also connected to the real phone's still-installed **stock** port5555, and the USI parser correctly rejected its incompatible framing. That does not test the new ARKit app on hardware.

The initial custom build at commit28fbc6a passed Python tests, Swift wire/mailbox tests, native compilation and unsigned packaging in run40638434877. The separate-app identity build at4ae3f77 also passed in run40639459031, and the user installed it. The user then reported a partly off-screen Home menu in landscape. The approved UI update preserves UIKit's safe-area constraints, provides centered multiline mode buttons and separates live status from Diagnostics. Its native build/layout checks and on-phone visual confirmation are still pending. G3 USB operation remains untested. Stock G2's measured30-FPS result is not a G3 result.

The wire contract is in [the design](superpowers/specs/2026-10-27-usi-stream-design.md). Port5558 is a separate USI2/version1 protocol, not stock PeerTalk. Every FRAME preserves session/sequence, raw ARKit seconds, phone uptime, 4x4 camera transform, position/quaternion, source/transmitted intrinsics, tracking, modality dimensions/encodings and explicit drop counters. RGB and depth are associated through the ARFrame; there is no invented independent LiDAR timestamp. Preview is independently throttled and outside raw pixels.

## Publish and build from Codespaces

To apply the approved UI update, upload the laptop's `suction-umi-v2-ui-update.bundle` into the Codespaces Explorer, then run these commands in the Codespace's repository terminal. It includes the earlier Home constraint correction and can fast-forward from the separate-app build at4ae3f77 or its Home correction at556a21c:

```bash
git fetch ./suction-umi-v2-ui-update.bundle usi-v2/g3-arkit-usb &&
git merge --ff-only FETCH_HEAD &&
git push origin main
```

Keep the bundle and older `usi_bundle` directory untracked; do not add them to a commit. The incremental bundle includes the previously prepared build-number correction. No force push is needed. If the repository advanced independently, preserve those commits and resolve the history before retrying.

On GitHub's website open Actions → **Suction UMI v2 iOS build** → Run workflow on main. Use the website because the existing Codespaces integration credential previously returned403 for workflow dispatch. The original **Stock iPhUMI unsigned iOS build** still deliberately builds pinned upstream; it will not compile G3.

The custom workflow checks Python tests and Swift framing/mailbox tests, installs locked pods, runs native layout probes, then archives the current custom revision. The probes render the actual UIKit Home, Live and Diagnostics views at normal and largest accessibility text sizes on iPhone15Pro and compact iPhoneSE3 simulators. They check navigation-control visibility/touch size, label clipping and unwanted horizontal scrolling, including a640×480 image and long status strings. Screenshots and JSON results are retained under `layout/` in the artifact. These probes do not exercise the camera, USB or physical VoiceOver interaction. The workflow supplies a nonempty `CFBundleVersion` (`3.<run number>`), verifies the separate bundle ID and display name before packaging, and emits `Suction-UMI-v2-unsigned.ipa`. Download its `suction-umi-v2-unsigned-<run id>` artifact ZIP from the actual successful run. Diagnostics can exist on a failed run, so confirm all required steps succeeded.

## Sign/install and enter the mode

Use the same verified iloader path/account to import the **new Suction UMI v2 IPA**. Its source bundle ID is distinct from iPhUMI, so install it as a separate app and retain the stock app. Keep a stable generated identity for future updates to Suction UMI v2 itself. Account credentials, pairing records and signed provisioning profiles stay private.

After installation, open **Suction UMI v2**. If a prior mode is restored, use its Home/back control to reveal the menu. The root controller restores a saved mode only once per launch, so returning Home reveals all three entries. Select **Live USB Stream**. The phone should show normal RGB alongside USB, tracking, capture rate and current-frame depth availability. Pressure is explicitly unavailable in this build and host recording is not reported; neither is inferred from a USB connection. No jaw calibration or ultrawide initialization is required for this new path.

Use **Diagnostics** for camera XYZ, session identifier, thermal state and encode drops. Opening/closing Diagnostics keeps capture running. **Diagnostics → Reset Tracking… → Reset Tracking** deliberately starts a fresh ARSession/UUID world epoch; cancelling leaves tracking running. **Home** stops capture and the USB listener. Backgrounding stops capture; foregrounding starts a new epoch. Larger text may scroll vertically; the main Home and Diagnostics controls remain outside the live status scroller. Fonts scale with Dynamic Type and controls have text labels for VoiceOver.

Before the USB acceptance test, check on the actual phone that all three Home buttons are reachable, the live view fits in landscape, Diagnostics opens/closes without resetting the session, cancelling Reset Tracking does not reset it, and larger accessibility text remains readable by scrolling. Test VoiceOver navigation on the device separately; a simulator screenshot alone cannot verify it.

## Run on the Ubuntu laptop

The existing separate `.venv-usb` contains optional preview dependencies. The new host needs no pypeertalk; it speaks directly to local usbmuxd. From the **laptop terminal**, not Codespaces:

```bash
cd ~/usi_ws/usi_v2/iPhUMI
env -u PYTHONHOME PYTHONPATH="$PWD" ../.venv-usb/bin/python -B -m usi_stream.receiver --metadata-log ../usi-g3-test.jsonl
```

For a console-only test:

```bash
cd ~/usi_ws/usi_v2/iPhUMI
env -u PYTHONHOME PYTHONPATH="$PWD" ../.venv-usb/bin/python -B -m usi_stream.receiver --headless --metadata-log ../usi-g3-test.jsonl
```

The preview combines RGB, false-colored depth (0–3m display range) and confidence if available. Display colors/range do not modify raw depth. Press q/Escape or Ctrl+C to stop. The JSONL is diagnostic frame metadata and timing observations, **not a complete raw-image record or MCAP dataset**. Do not commit it. Source sessions/sequence gaps include acquisitions before first connection; they are not all USB transmission loss.

The camera frame is `arkit_camera`: x right, y up, z back. `camera_transform_row_major` is `W_T_C`. Quaternion order is x,y,z,w, position meters. No ROS optical conversion or default jaw/suction transform is applied. The new mode targets an available30-FPS ARKit video format; actual capture/receive rates must be measured. Original ARKit seconds and system-uptime nanoseconds remain separately labeled. Raw four-timestamp USB ping/pong observations are logged, but no synchronized source-time correction is asserted.

## Actual G3 phone acceptance

1. With phone fixed, inspect stable normal tracking and advancing sequences/source time; observe raw depth/confidence presence and actual dimensions.
2. Translate roughly20cm along each direction and rotate gently. Compare camera XYZ/quaternion changes and saved raw transform; document signs/units, without claiming a suction TCP.
3. Reset tracking: verify a new session UUID and sequence epoch. Frames from the old ARSession must not be relabeled into the new epoch.
4. Unplug/reconnect USB: verify disconnection diagnostics, bounded memory and a new handshake; source sequence gaps remain explicit. No false recorder-ready state exists because MCAP is not running yet.
5. Run30 seconds, then a longer thermal/drop test only if the short test is stable. Record capture/receive rates, both encode/transport drop counts and source-sequence gaps separately. Missing depth must stay null rather than a manufactured repeated sample.

Save the actual build provenance, run results, diagnostic JSONL and measured observations. Only these on-device tests can close G3. Later gates add simulated pressure UI, BLE, ROS/Jazzy typed metadata/MCAP and physically measured calibration.
