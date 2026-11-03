# Suction UMI v2 — UI-first update

This update uses the existing ARKit/USB camera path with the approved native collection layout. The unfinished collection infrastructure is kept on the separate `usi-v2/g4-integrated-collection` branch.

- Collect Demonstrations opens the new screen; original iPhUMI modes are under Advanced.
- Live RGB uses RealityKit with the existing ARSession, independent of JPEG encoding. Capture requests a supported 60 FPS format and reports observed acquisition FPS.
- Depth shows actual ARKit depth as a grayscale visualization: near is light, invalid is black, display range 0–2 m. The existing raw USB depth bytes are unchanged. The depth preview updates with encoded frames, up to 10 times per second.
- Ultrawide has an explicit unavailable message; this path does not invent a concurrent image.
- One circle contains three equal 120-degree sectors, numeric pressure rows, and a separate suction readout. Unconnected sensor readings stay unknown/gray.
- The fixed trial bar contains trial number, state, timer and Start/Stop. Recording is not connected in this UI build. Start explains this and never simulates a recording or Saved result.
- Data shows capture/pose/USB details and the availability of each pending stream. Settings save session/task/gripper/calibration labels locally. Opening either keeps capture running.

## Build and install

Upload `suction-umi-v2-ui-first.bundle` to the Codespaces repository root, then run:

```bash
git bundle verify ./suction-umi-v2-ui-first.bundle &&
git fetch ./suction-umi-v2-ui-first.bundle usi-v2/ui-first &&
git merge --ff-only FETCH_HEAD &&
git push origin main
```

Run **Suction UMI v2 iOS build** on `main`. Leave the optional simulator layout checks unchecked for the fast build. Download the `suction-umi-v2-UI-first-<run ID>` artifact, extract it, and import **Suction-UMI-v2-UI-first.ipa** into iLoader. Build numbers use series `4`; Data shows the revision. This updates Suction UMI v2 and retains its separate app identifier.

The local Linux checks cover Swift syntax and the existing protocol/mailbox tests. UIKit/RealityKit SDK compilation happens in GitHub Actions; actual layout/camera behavior needs the phone. Sensor/trigger reception, calibrated seal classification and host-controlled verified MCAP trials are the next integration stage.

## Camera layout follow-up

The header now has a compact 48-point height and the trial bar uses 52 points at normal text size. The remaining space expands the camera instead of stretching the header. XYZ, tracking, FPS/depth details and USB status are in the scrollable side panel, outside both RGB and depth previews. The optional native layout probe checks that the camera is tall, starts near the top, and has no readout overlap.

Upload `suction-umi-v2-camera-layout.bundle` and fetch its `usi-v2/ui-first` ref using the same fast-forward commands above. The next artifact is named `suction-umi-v2-camera-layout-<run ID>` and contains **Suction-UMI-v2-camera-layout.ipa**. This update builds on UI revision `3281a30` without including the unfinished infrastructure branch.
