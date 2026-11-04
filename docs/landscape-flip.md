# Mounted phone landscape rotation

The phone app now declares both landscape directions. Previously its Info.plist
allowed only landscape-right, so turning a mounted phone 180 degrees could not
turn the controls upright. Portrait is still excluded.

ARView handles RGB presentation rotation. The depth preview, depth thumbnail and
JPEG fallback rotate their display 180 degrees in landscape-left. This does not
rotate recorded sensor pixels, change intrinsics or modify ARKit poses.

Upload `suction-umi-v2-landscape-flip.bundle` to the Codespace repository root:

```bash
git fetch ./suction-umi-v2-landscape-flip.bundle usi-v2/landscape-flip &&
git merge --ff-only FETCH_HEAD &&
git push origin main
```

Run **Suction UMI v2 iOS build** on `main`, with simulator layout checks unchecked.
Install its new **Suction-UMI-v2-recording.ipa** through iLoader over the existing
Suction UMI v2 app. The bundle also includes the previously prepared host seal
label correction and raw dataset inspection tool; no firmware change is needed.

Before a trial, turn off iPhone Rotation Lock in Control Center. Hold the mounted
assembly upright in the desired landscape direction; if necessary tilt it through
portrait and back. Check Home, Collect Demonstrations, Settings and Data are
upright, and that RGB and Depth show the scene in the same direction.

Validation on Ubuntu: checked the plist and parsed the modified Swift source.
The packaged app's orientation list is also checked by the iOS build workflow.
Native compilation and a physical rotation check require the new iPhone build.
