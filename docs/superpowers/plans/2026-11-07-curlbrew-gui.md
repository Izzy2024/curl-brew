# Curlbrew Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Una app SwiftUI arm64, al estilo de BrewUI, que administra Homebrew, npm, pnpm y bun y ejecuta solo instaladores `curl` de una lista blanca.

**Architecture:** `CellarCore` define paquetes, el localizador de binarios y un ejecutor de argv que rechaza shells. `CellarProviders` habla con cada CLI y con el registro npm. `CurlbrewApp` muestra el comando y pide confirmación antes de correrlo. Los comandos de gestores usan cwd `/private/tmp` para no engancharse a un `package.json` del usuario.

**Tech Stack:** Swift 6.4 en modo de lenguaje Swift 5, SwiftUI, SwiftPM, macOS 14+, arm64. Sin Xcode: Command Line Tools.

---

## Alcance

Incluido: inventario, búsqueda, instalar, desinstalar y actualizar de Homebrew (fórmula y cask), npm, pnpm y bun; catálogo curl con confirmación; registro de stdout/stderr.

Fuera de este corte: cargo, gem, pip, go y Mac App Store como inventarios completos. Esos ecosistemas se pueden detectar después. Nix y sdkman no entran hasta verificar el comando oficial vigente.

“pmp” del pedido es pnpm.

M3 entra en el mismo binario arm64 aunque no se nombró.

## Archivos

- `Sources/CellarCore/` — modelos, `BinaryLocator`, `ProcessCommandRunner`, `ScriptedRunner`
- `Sources/CellarProviders/` — Homebrew, npm, pnpm, bun, `CurlCatalog`, `AllowlistedShellRunner`
- `Sources/CurlbrewApp/` — ventana, hojas de búsqueda y confirmación, registro
- `Tests/CellarCoreTests/` y `Tests/CellarProvidersTests/`
- `Scripts/package-app.sh` — `Curlbrew.app` arm64

## Tareas de los panes

Los tres panes ya están en la sesión `curl-brew-gui`. No editan el mismo archivo.

- [ ] **providers** (`block:01a1b719-082f-73dc-8245-a84c0799c414`): `docs/agents/providers.md`. Muestras reales de solo lectura y un test Swift Testing. Sin instalar ni borrar paquetes.
- [ ] **interfaz** (`block:01a1b89e-1ec2-7478-8dc3-0f718fbb1dd9`): `docs/agents/ui.md`. Botón Copiar comando en la ficha y en la confirmación.
- [ ] **catalogo** (`block:01a1b89d-581c-71f0-a5bc-45a2bbace42f`): `docs/agents/catalog.md`. Verificar los comandos oficiales. Nix y sdkman solo con un `curl` de una línea publicado por el proyecto.

## Verificación

```bash
make test
make app
file Curlbrew.app/Contents/MacOS/Curlbrew
open Curlbrew.app
```

Esperado: tests en verde, binario `arm64`, la ventana abre y el registro muestra el comando antes de ejecutarlo.
