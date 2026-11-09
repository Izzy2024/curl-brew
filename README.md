# Curlbrew

**English** · [Español](README.es.md)

A native macOS app to browse and manage **Homebrew, npm, pnpm and bun**, and to run official `curl` installers with the command in plain sight.

The idea comes from [BrewUI](https://github.com/Homebrew/brewui): a window for people who don't want to live in the terminal, **without hiding what is about to run**. Every action shows the exact command and asks for confirmation before running it.

The code is independent. BrewUI is AGPL and this project does not reuse its code.

<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Curlbrew icon">
</p>

## Requirements

- macOS 14 (Sonoma) or later
- **Apple Silicon** (M1–M5). The binary is arm64; there is no Intel slice.
- Command Line Tools or Xcode. This machine builds with the Command Line Tools alone.

## Install

Download `Curlbrew-<version>.dmg` from [Releases](../../releases), open it and drag **Curlbrew** into **Applications**.

The signature is **ad-hoc**, not notarized: there is no Apple developer account. macOS will ask for confirmation the first time. Open with **right-click → Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/Curlbrew.app
```

## App updates

A push to `main` does not update anyone who already installed Curlbrew. The installed copy only changes when a [release](https://github.com/Izzy2024/curl-brew/releases/latest) exists with a `vX.Y.Z` tag higher than its own, plus the `Curlbrew-X.Y.Z.zip` asset.

The version the bundle carries today, when no other is passed, is `0.1.0`. The first release the public can install must be higher, for example `v0.2.0`. An older copy without the update button will not notice on its own: that first release has to be installed by hand.

### If you already have it in Applications

1. Open **Curlbrew** from `/Applications`, not from the download or the mounted DMG. If macOS opened it in quarantine, move it to Applications and open it from there.
2. On launch it checks the latest release. There is also **Check for Update** in the toolbar and in Overview.
3. If there is a newer version, the button becomes **Update to X.Y.Z**. The sheet shows the zip URL.
4. **Update** downloads that zip, checks it contains `Curlbrew.app` with identifier `app.curlbrew.macos` and that version, on arm64, replaces the running copy and reopens it.

The log at the bottom records the commands (`ditto`, `lipo`, `xattr`). If GitHub has no releases yet, the notice says no version has been published.

### How to publish it

The change must be in the commit you tag. Then:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The tag must be `v` plus three numbers (`v0.2.0`). `v0.2` or `v0.2.0-beta` neither trigger the workflow nor get offered by the app. The number must be higher than the installed copies: `0.10.0` is higher than `0.9.0`.

That runs `.github/workflows/release.yml` on an arm64 Mac. The workflow builds with `CURLBREW_VERSION` set to the tag, signs the app and publishes two files to the release:

| File | Purpose |
| --- | --- |
| `Curlbrew-0.2.0.zip` | Downloaded by the **Update** button |
| `Curlbrew-0.2.0.dmg` | First install: drag it to Applications |

The bundle version comes from the tag. Locally, with no tag, `make app` still produces `0.1.0`. To try another number: `CURLBREW_VERSION=0.2.0 make app`.

The signature is still ad-hoc. Whoever receives the update trusts this repository's release, not an Apple notarization.

## Build from source

```bash
git clone https://github.com/Izzy2024/curl-brew.git
cd curl-brew

make test     # tests
make app      # builds and signs Curlbrew.app
make dmg      # packages dist/Curlbrew-<version>.dmg

open Curlbrew.app
```

`make` builds into `/tmp/curlbrew-build`. The project folder may live on a volume that stamps Finder metadata onto directories, and `codesign` rejects the test bundle if `.build` stays there.

`make dmg` needs [create-dmg](https://github.com/create-dmg/create-dmg):

```bash
brew install create-dmg
```

The interface is SwiftUI, but without `@State` or `@Bindable`: the Command Line Tools do not include the `SwiftUIMacros` plugin. State lives in `AppModel`.

## What it manages

| Manager | Inventory | Search / install / remove / upgrade |
| --- | --- | --- |
| Homebrew | formulae and casks | yes, via `brew` with arguments, no shell |
| npm | global packages | yes |
| pnpm | global packages | yes. In conversation, "pmp" means pnpm |
| bun | `~/.bun/install/global/package.json` | yes, always with `--global` |

`curl` installers only run if the text matches the allowlist in `CurlCatalog`. That includes Magpie (`curl -fsSL https://usemagpie.ai/install.sh | sh`): the app lands in `/Applications/magpie.app` or `~/Applications/magpie.app`, and the command in `~/.local/bin/magpie`. Removing it uses the same script with `--uninstall` and leaves `~/.config/magpie` in place.

A package name cannot be a flag (`--force`) and is passed as an argument, never inside a shell string.

`bun outdated --global` is not used: on macOS it walks parent directories and lists a project that is not the global one.

## Updates first

Each manager's list opens sorted **updates first**: anything with a new version sits on top, in its own section with a count, and the rest below under "Up to date". No digging through hundreds of packages.

- **Overview** lists every pending update, grouped by manager, with `installed → available` and a button per package. There is also "Update all" per manager. The sidebar and Overview badges show the total.
- Toolbar filters: **Updates only**, **Sort** (updates first, name, version) and **Kind** (formula, cask, global).
- Search looks at name and summary. Switching managers resets the filters so the list is never left empty.

The ordering lives in `CellarCore/PackageOrdering.swift` and is tested without UI in `Tests/CellarCoreTests/CoreTests.swift`. Version comparison is numeric per component: `1.10.0` is higher than `1.9.2`.

## Security

Nothing runs blindly:

- Commands are built as `argv`, with no `zsh -c`. A package name is never interpreted as shell.
- `curl` installers go through `AllowlistedShellRunner`, which only accepts the exact lines in `CurlCatalog`.
- Before running, a confirmation sheet shows the full command, with an option to copy it.
- Operations can be **stopped**; the log stays visible at the bottom.

## Layout

```
Sources/
  CellarCore/        models, binary locator, argv runner, ordering and filters
  CellarProviders/   Homebrew, npm, pnpm, bun and the curl installer catalog
  CurlbrewApp/       SwiftUI interface and AppModel
Tests/               Core and Providers tests, with real fixtures from each CLI
Scripts/             package-app.sh (bundle + signing) and package-dmg.sh (DMG)
.github/workflows/   release.yml publishes zip and DMG when tagging vX.Y.Z
Resources/           icon and DMG background
docs/                implementation plan
```

| Module | Responsibility |
| --- | --- |
| `CellarCore` | `InstalledPackage`, `PackageUpgrade`, `PackageOrdering`, `AppUpdateFeed`, `BinaryLocator`, `ProcessCommandRunner` |
| `CellarProviders` | one `PackageProvider` per manager; `CurlCatalog` for the installers |
| `CurlbrewApp` | `RootView` (sidebar), `ProviderBrowser`, `InstallerBrowser`, `AppModel` (state and operations) |

## The DMG

`make dmg` builds, signs and packages `dist/Curlbrew-<version>.dmg` with [create-dmg](https://github.com/create-dmg/create-dmg). The DMG opens a window with the app icon and an `/Applications` link: drag one onto the other and it is installed. The background is `Resources/dmg-background.png` (1320×840, i.e. 660×420 at 2x).

Opening it without the Gatekeeper warning would require a Developer ID certificate and notarization with `notarytool`.

## Credits

The icon is the yin-yang from [Icons8](https://icons8.com), in `Resources/AppIcon.png`.

## License

MIT. See [LICENSE](LICENSE).
