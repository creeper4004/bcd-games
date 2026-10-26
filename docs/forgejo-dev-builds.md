# Local development IPAs with Forgejo

The private `creeper/bcd-games` repository on `forgejo.internal` runs
`.forgejo/workflows/dev-ipa.yml` on pushes to `main`, `experiment/**` and
`dev/**`, or by manual dispatch. Forgejo on TMR coordinates the jobs and stores
the artifacts. The repository-scoped `bcd-macos-arm64` worker runs Xcode on the
Mac. The Mac must be awake, connected, and logged in for its LaunchAgent to run.
The job keeps it awake while compiling; it does not change system sleep settings.

Open the repository's **Actions** tab and select a completed **BCD development
IPA** run. Download its `bcd-dev-<commit>-<run>` artifact, unzip it, and import the
IPA into iLoader. The package also contains SHA-256, `BUILD-INFO.json` with the
exact source commit and component cache keys, and the build/check logs. Failed
runs retain their logs too. Artifacts expire after seven days.

These IPAs use an ad-hoc signature carrying the sideload entitlements. iLoader
still signs them for the phone. The CI worker needs no Apple ID, developer
certificate, OTA bucket, public GitHub Actions job or signing/publishing secret.
The existing upstream build/release workflow is separate. No PR event targets
this local worker.

## Build strategy and limits

The first run initializes its own checkout, submodules, native build trees and
Windows renderers. Subsequent runs reuse persistent components when their
source, recipe, Xcode and configuration keys match. The app is archived from the
pushed commit; local developer worktrees are not reset or used as build outputs.
Only one job builds at a time, and pushes queue rather than interrupt a build
that is updating the persistent cache.

`build/dev-ipa/base.json` pins the official upstream IPA used for unchanged
Windows runtime farms. The source-built DXMT D3D11/D3D9 renderers replace their
base counterparts, including i386. BCD's native libraries and UI come from the
checked-out source. This avoids rebuilding every unchanged Wine DLL for a UI or
HDR experiment. Wine/FEX pin changes and changes to the guarded guest-runtime
inputs stop the build with an explanation: update the verified base or use a
full PE build, rather than silently package incompatible old DLLs.

The preinstalled LLVM, MinGW, GnuTLS, FFmpeg, FreeType, Metal converter and verified
base IPA are configured outside Git in `~/.config/bcd-forgejo-runner/build.json`.
The private runner connection is in `config.yml` beside it (mode 0600).
`tools/build-dev-ipa.py` reads the path from `BCD_CI_CONFIG`. Its dedicated build
checkout and component stamps live under `~/Library/Caches/bcd-forgejo/build/`;
job workspaces live under `~/Library/Caches/bcd-forgejo/jobs/`. The Xcode tools,
Rust iOS target, CMake, Ninja, Meson, bison/flex and Python/PyYAML must be installed
on that worker.

## Worker operation

The login service is `local.bcd.forgejo-runner`, configured in
`~/Library/LaunchAgents/local.bcd.forgejo-runner.plist`. Logs are in
`~/Library/Logs/bcd-forgejo/`. TMR can reach the Mac through its existing `ssh mbp`
alias; the worker normally polls Forgejo directly.

To restart it on the Mac:

```sh
launchctl kickstart -k gui/$(id -u)/local.bcd.forgejo-runner
```

To list or download artifacts with the configured Forgejo CLI:

```sh
fj -H http://forgejo.internal:3000 --json actions artifact --repo creeper/bcd-games list
fj -H http://forgejo.internal:3000 actions artifact --repo creeper/bcd-games download ARTIFACT_ID --output build.zip
```
