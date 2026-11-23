# Changelog

All notable changes to Curlbrew will be documented in this file.

## [0.3.2] - 2026-11-23

### Fixed
- Reabre la ventana principal al hacer clic en el Dock cuando la app quedó en segundo plano con la ventana cerrada; también restaura la ventana minimizada u oculta (Cmd+H) en lugar de dejar la app activa sin nada que ver.

### Changed
- `make app` toma la versión del último tag cuando no se indica `CURLBREW_VERSION`, y firma el bundle fuera de la carpeta Documents para que codesign no lo rechace.

## [0.3.1] - 2026-11-16

### Security & Hardening
- Isolated package-manager working directory to a private `0700` per-user directory instead of `/private/tmp`.
- Added `--` end-of-options separators in `NpmProvider`, `PnpmProvider`, and `BunProvider`, and rejected leading `/` in `PackageName.isValid`.
- Filtered relative `PATH` entries in `BinaryLocator.mergedSearchPaths` and enforced regular-file checks in `BinaryLocator.locate`.
- Added SHA-256 digest verification (`CryptoKit`), `codesign --verify --deep --strict`, and atomic `replaceItemAt` replacement in `AppUpdateInstaller`.
- Restricted `PackageDetail` homepage `Link` rendering to `http`/`https` URLs and aligned `AppModel.isShell` with `ProcessCommandRunner.isShell`.
- Added `make test` gate and `.zip.sha256` checksum publishing in `.github/workflows/release.yml`.

## [0.3.0] - 2026-11-16

### Added
- **Copy all logs button**: Added a "Copiar" button in the bottom `Registro` panel to copy the complete log history to the system clipboard, with a status confirmation banner.
- **Live download progress bar**: Real-time progress tracking both in the CLI log lines and in the UI header.
  - Homebrew: allocates a pseudo-terminal (`openpty`) on stdout so `DownloadQueue` emits live byte and percentage progress frames.
  - npm: enabled `npm_config_loglevel=http` to report live download and registry fetch events.
  - pnpm & curl: live progress and percentage parsing with dynamic ASCII bar in logs and a linear progress bar in the UI.
  - Dynamic byte progress calculation (`X MB / Y MB`, remaining time/bytes, and percentage).

## [0.2.0] - 2026-11-08

### Added
- In-app self-update via GitHub Releases with bundle verification and auto-relaunch.
- Multi-step execution resilience: continuing with remaining packages if an individual package upgrade fails.
- English and Spanish documentation.

## [0.1.0] - 2026-11-08

### Added
- Initial release of Curlbrew: macOS native management for Homebrew, npm, pnpm, bun, and allowlisted curl installers.
