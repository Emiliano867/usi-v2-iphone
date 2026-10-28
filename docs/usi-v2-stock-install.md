# USI v2: separate repository and stock iPhUMI install gate

This checkout is intended for **Emiliano867/usi-v2-iphone**, separate from the legacy USI project. Application sources remain those of public upstream iPhUMI commit `1e9e622e77ad32990c42f839e12212d2a995faf9`. Only this guide and a manually triggered build workflow are added for G1. No USI firmware, recordings or private handoff documents belong in this repository.

## 1. Create the separate GitHub repository

While signed in as Emiliano867, use [the prefilled new-repository form](https://github.com/new?owner=Emiliano867&name=usi-v2-iphone&description=USI+v2+iPhone+application+and+stock+iPhUMI+build+validation).

Choose **Public** only for the public upstream app and this build tooling if you want GitHub's free standard hosted-runner route. A private repository uses your account's included allowance and can incur charges beyond it; inspect your account budget first. Future confidential USI research changes need a separate visibility decision. Do **not** initialize a README, .gitignore or license: this checkout already contains upstream files and history. Click **Create repository**. See [GitHub's repository creation instructions](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository) and [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

The local remotes are prepared:

```text
origin    https://github.com/Emiliano867/usi-v2-iphone.git
upstream  https://github.com/real-stanford/iPhUMI.git
```

After repository creation and local GitHub authentication, publish the prepared branch as the new repository's default branch:

```bash
cd /home/emi-linux/usi_ws/usi_v2/iPhUMI
git status --short --branch
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  git fetch --unshallow upstream
fi
git push -u origin usi-v2/g1-stock-build:main
```

Full upstream history was fetched during setup; the conditional also supports a fresh shallow clone. Authenticate through your own GitHub client/device login or VS Code; do not paste passwords/tokens into chat. If you use GitHub CLI, `gh auth login` is interactive and belongs in your terminal. Publishing is pending until the remote actually exists and the push succeeds.

## 2. Run the stock build

Open the new repository → **Actions** → **Stock iPhUMI unsigned iOS build** → **Run workflow** on `main`. If GitHub prompts to enable Actions for the new repository, enable it. The workflow has no push/PR trigger. It checks out the exact public upstream commit independently of the tooling branch, so later custom application edits cannot silently change this baseline.

The selected standard runner is `macos-26`, with `/Applications/Xcode_26.6.app/Contents/Developer`, based on the [published runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md). Hosted images change: if that exact Xcode disappears, preserve the failed run and intentionally select another published Xcode 26 toolchain. The workflow logs the actual OS, Xcode, SDK and image version; a runner label alone does not freeze an entire build image.

Dependency installation uses CocoaPods **1.16.2** and `pod install --deployment` against upstream's tracked lockfile: PeerTalk 0.1.0, Socket.IO-Client-Swift 16.1.0, Starscream 4.0.8. Ruby's transitive gem dependencies and the hosted image are not fully locked. No claim of byte-identical builds is made.

The workflow runs `xcodebuild archive` for a generic iOS device with signing disabled, then packages `Payload/iPhUMI.app` into `iPhUMI-stock-unsigned.ipa`. Download the run's `iphumi-stock-unsigned-*` artifact within its three-day retention. Preserve `provenance.txt`, `Podfile.lock`, `xcodebuild.log`, result bundle, IPA SHA-256 and `STATUS.txt`. A failed build may still have a diagnostics artifact; **artifact presence does not prove compilation passed**.

There is no local Xcode on Ubuntu. Local YAML/shell checks are not an iOS build. No cloud compilation or installation success is claimed before an actual successful run.

## 3. Try lawful free signing/install separately

An unsigned IPA cannot be launched on a normal iPhone as-is. Stock source has one application target, no tracked `.entitlements` file and no `CODE_SIGN_ENTITLEMENTS` setting; this makes a free-account trial reasonable, but does not prove SideStore can sign and install it or that all runtime features work.

On Ubuntu, follow the current official [SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites) and its linked installation instructions. They currently require an Apple Account, Wi-Fi for setup/refresh, iloader/usbmuxd on Linux and LocalDevVPN for SideStore install/update/refresh operations. That setup Wi-Fi does not change the required experimental USB streaming path. Use your Apple credentials only within the selected installer, and keep pairing material local.

After SideStore itself works, import the downloaded **unsigned IPA**, let the installer perform its own signing/provisioning, and record the exact outcome. If it rejects the IPA, reports unsupported entitlements/provisioning, or installation succeeds but launch fails, preserve the error text with personal identifiers removed. Do not call unsigned packaging an installation test. Free-account apps need periodic refresh; see [SideStore's FAQ](https://docs.sidestore.io/docs/faq.html) and [Apple's account limitations](https://developer.apple.com/help/account/basics/about-your-developer-account).

Fallback: on an available lab Mac with compatible Xcode 26, clone the pinned source, run `pod install --deployment` in `ios_app`, and open `iPhUMI.xcworkspace`. Select the iPhUMI target → Signing & Capabilities → **All**, choose your own free **Personal Team** and a stable unique bundle identifier. Connect/unlock/trust your phone, enable Developer Mode if requested, select the real phone and run **Debug**. Keep your account/certificates on that Mac. Do not use the upstream development team as your own. Upstream documents this free-account Xcode route and its weekly re-signing requirement in [usage.md](https://github.com/real-stanford/iPhUMI/blob/1e9e622e77ad32990c42f839e12212d2a995faf9/docs/usage.md).

## 4. On-device G1 verification

1. Launch the stock app; accept the permissions required by the features you test. Record iOS version and build provenance without UDID or account screenshots.
2. Enter **Data Collection** → Settings → temporarily enable **Viewer** (it defaults off) to verify the real rear-camera preview and changing pose coordinates. For this single-phone check, disable Multipeer Connectivity and Voice Commands. Move the phone a short measured distance and rotate it; inspect plausible pose changes. Turn Viewer off again before recording if it reduces FPS.
3. Set a session name such as `usi-stock-smoke`, select side **H (Head)**, demonstration type **Demo** rather than **Gripper cal**, and **no task labels** (X icon). Head mode bypasses the parallel-jaw calibration requirement for this camera-only baseline; it does not validate a suction gripper, TCP transform or actual head mount. Wait until measured FPS exceeds 50 and recording is enabled, record 5–10 seconds of slow motion, then stop and wait for saving to finish. If recording stays disabled, preserve the displayed unmet-condition message. Do not invent a jaw calibration for the suction tool.
4. Open **View Demonstrations** and inspect the saved demo's main RGB and depth. Inspect its metadata/pose output for nonempty transforms and plausible translation/rotation changes. Stock files have their own timestamps/formats; they do not establish the new USI synchronization contract. Failure to get valid depth or pose leaves that check open even if preview works.
5. Record **install**, **launch**, **RGB**, **LiDAR depth** and **6-DoF pose** as separate pass/fail observations. A preview alone does not verify pose or depth.

Do not install modified BLE/pressure code before this gate has evidence. A desktop cannot substitute for these on-device observations.

## 5. G2 stock USB smoke test after G1

Stock deployment entry requires the app's ARKit ultrawide lens-position calibration value: enter **Data Collection** for a few seconds first, return to the main screen, then open **Deployment**. Select **USB**, start with **30 FPS**, **Low (320×240)** and enable **Depth**. The code defaults to 60 FPS and depth off, so explicitly inspect the settings.

On Ubuntu, recheck pairing and the **phone's branch** in `lsusb -t`. If it remains `480M`, use a USB 3 data-rated cable and suitable port, then recheck before high-bitrate trials. `480M` does not prove the stock stream will fail, and no cable bottleneck diagnosis is established without the retest.

Use the pinned upstream Python environment/setup and its actual test script. Explicitly include `python_package` on the import path because this commit uses `find_packages()` without tracked `__init__.py` files:

```bash
cd /home/emi-linux/usi_ws/usi_v2/iPhUMI
export PYTHONPATH="$PWD/python_package${PYTHONPATH:+:$PYTHONPATH}"
python python_package/iphumi/deployment/test_iphone_usb_streaming.py --streams main depth
```

The environment needs `pypeertalk`, OpenCV, NumPy and module-level Flask/Flask-SocketIO/qrcode dependencies; see the pinned `python_package/environment.yml`, `setup.py`, and source-audit report before installing into a separate environment. Do not install those into system ROS Python. The command explicitly selects main and depth; without `--streams`, the stock script also starts ultrawide. Its display needs a desktop session. Avoid `--get-ids` or multi-device identification output in shared logs.

Record actual formats, counts/rates, image validity, gaps and reconnect behavior. Stock main/ultrawide ports are 5555/5556; depth is 5557. The host expects raw float32 depth shaped 240×320, but the sender's format/stride still needs measurement. **Stock USB does not carry ARKit pose or the new USI source timing metadata.** Passing G2 validates transport for stock camera streams only.
