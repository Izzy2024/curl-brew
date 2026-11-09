# Curlbrew

[English](README.md) · **Español**

App nativa de macOS para ver y administrar **Homebrew, npm, pnpm y bun**, y para lanzar instaladores oficiales por `curl` con el comando a la vista.

La idea es la de [BrewUI](https://github.com/Homebrew/brewui): una ventana para quien no quiere vivir en la terminal, **sin esconder qué se va a ejecutar**. Cada acción muestra el comando exacto y pide confirmación antes de correrlo.

El código es independiente. BrewUI es AGPL y este proyecto no reutiliza su código.

<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Icono de Curlbrew">
</p>

## Requisitos

- macOS 14 (Sonoma) o posterior
- **Apple Silicon** (M1–M5). El binario es arm64; no hay slice Intel.
- Command Line Tools o Xcode. En esta máquina se compila solo con las Command Line Tools.

## Instalar

Descarga `Curlbrew-<versión>.dmg` desde [Releases](../../releases), ábrelo y arrastra **Curlbrew** a la carpeta **Applications**.

La firma es **ad-hoc**, no notarizada: no hay cuenta de desarrollador Apple. La primera vez macOS pedirá confirmación. Abre con **clic derecho → Abrir**, o quita la cuarentena:

```bash
xattr -dr com.apple.quarantine /Applications/Curlbrew.app
```

## Actualizaciones de la app

Un push a `main` no actualiza a quien ya instaló Curlbrew. La copia instalada solo cambia cuando existe una [release](https://github.com/Izzy2024/curl-brew/releases/latest) con un tag `vX.Y.Z` mayor que el suyo, y el zip `Curlbrew-X.Y.Z.zip`.

La versión que lleva el bundle hoy, si no se pasa otra, es `0.1.0`. La primera release que el público pueda instalar tiene que ser mayor, por ejemplo `v0.2.0`. Una copia anterior, sin el botón de actualizar, no se entera sola: hay que instalar esa primera release a mano.

### Quien ya la tiene en Aplicaciones

1. Abre **Curlbrew** desde `/Applications`, no desde la descarga ni desde el DMG montado. Si macOS la abrió en cuarentena, muévela a Aplicaciones y ábrela desde ahí.
2. Al arrancar consulta la última release. También está **Buscar actualización** en la barra y en Resumen.
3. Si hay versión nueva, el botón pasa a **Actualizar a X.Y.Z**. La hoja muestra la URL del zip.
4. **Actualizar** descarga ese zip, comprueba que dentro va `Curlbrew.app` con identificador `app.curlbrew.macos` y esa versión, en arm64, reemplaza la copia abierta y la vuelve a abrir.

El registro de abajo deja los comandos (`ditto`, `lipo`, `xattr`). Si GitHub todavía no tiene releases, el aviso es que no hay una versión publicada.

### Cómo publicarla

El cambio tiene que estar en el commit que etiquetas. Luego:

```bash
git tag v0.2.0
git push origin v0.2.0
```

El tag tiene que ser `v` y tres números (`v0.2.0`). `v0.2` o `v0.2.0-beta` no disparan el workflow ni las ofrece la app. El número tiene que ser mayor que el de las copias ya instaladas: `0.10.0` es mayor que `0.9.0`.

Eso corre `.github/workflows/release.yml` en un Mac arm64. El workflow compila con `CURLBREW_VERSION` igual al tag, firma la app y publica dos archivos en la release:

| Archivo | Para qué |
| --- | --- |
| `Curlbrew-0.2.0.zip` | Lo descarga el botón **Actualizar** |
| `Curlbrew-0.2.0.dmg` | Primera instalación: se arrastra a Aplicaciones |

La versión del bundle sale del tag. En local, sin tag, `make app` sigue dejando `0.1.0`. Para probar otro número: `CURLBREW_VERSION=0.2.0 make app`.

La firma sigue siendo ad-hoc. Quien recibe la actualización confía en la release de este repositorio, no en una notarización de Apple.

## Compilar desde el código

```bash
git clone https://github.com/Izzy2024/curl-brew.git
cd curl-brew

make test     # pruebas
make app      # compila y firma Curlbrew.app
make dmg      # empaqueta dist/Curlbrew-<versión>.dmg

open Curlbrew.app
```

`make` compila en `/tmp/curlbrew-build`. La carpeta del proyecto puede estar en un volumen que marca los directorios con metadatos de Finder, y `codesign` rechaza el bundle de tests si `.build` se queda ahí.

`make dmg` necesita [create-dmg](https://github.com/create-dmg/create-dmg):

```bash
brew install create-dmg
```

La interfaz es SwiftUI, pero sin `@State` ni `@Bindable`: las Command Line Tools no incluyen el plugin `SwiftUIMacros`. El estado vive en `AppModel`.

## Qué administra

| Gestor | Inventario | Buscar / instalar / quitar / actualizar |
| --- | --- | --- |
| Homebrew | fórmulas y casks | sí, con `brew` y argumentos, sin shell |
| npm | paquetes globales | sí |
| pnpm | paquetes globales | sí. En la conversación, “pmp” es pnpm |
| bun | `~/.bun/install/global/package.json` | sí, siempre con `--global` |

Los instaladores `curl` solo se ejecutan si el texto coincide con la lista blanca de `CurlCatalog`. Ahí está Magpie (`curl -fsSL https://usemagpie.ai/install.sh | sh`): la app queda en `/Applications/magpie.app` o `~/Applications/magpie.app`, y el comando en `~/.local/bin/magpie`. Quitarlo usa el mismo script con `--uninstall` y deja `~/.config/magpie`.

El nombre de un paquete no puede ser una bandera (`--force`) y entra como un argumento, nunca dentro de una cadena de shell.

`bun outdated --global` no se usa: en macOS recorre directorios padres y lista un proyecto que no es el global.

## Actualizaciones primero

La lista de cada gestor abre ordenada por **actualizaciones primero**: lo que tiene versión nueva queda arriba, en su propia sección con el número, y lo demás debajo en “Al día”. No hay que buscar entre cientos de paquetes.

- **Resumen** lista todas las actualizaciones pendientes, agrupadas por gestor, con `instalada → disponible` y un botón por paquete. También hay “Actualizar todo” por gestor. El badge del sidebar y del Resumen cuenta el total.
- Filtros de la barra: **Solo actualizaciones**, **Orden** (actualizaciones primero, nombre, versión) y **Tipo** (fórmula, cask, global).
- La búsqueda mira nombre y resumen. Al cambiar de gestor los filtros se reinician para no dejar la lista vacía.

El orden vive en `CellarCore/PackageOrdering.swift` y se prueba sin UI en `Tests/CellarCoreTests/CoreTests.swift`. La comparación de versiones es numérica por trozos: `1.10.0` es mayor que `1.9.2`.

## Seguridad

Nada se ejecuta a ciegas:

- Los comandos se arman como `argv`, sin `zsh -c`. Un nombre de paquete nunca se interpreta como shell.
- Los instaladores `curl` pasan por `AllowlistedShellRunner`, que solo acepta las líneas exactas de `CurlCatalog`.
- Antes de ejecutar, una hoja de confirmación muestra el comando completo, con opción de copiarlo.
- Las operaciones se pueden **detener**; el registro queda visible en la parte inferior.

## Estructura

```
Sources/
  CellarCore/        modelos, localizador de binarios, ejecutor de argv, orden y filtros
  CellarProviders/   Homebrew, npm, pnpm, bun y el catálogo de instaladores curl
  CurlbrewApp/       interfaz SwiftUI y AppModel
Tests/               pruebas de Core y Providers, con fixtures reales de cada CLI
Scripts/             package-app.sh (bundle + firma) y package-dmg.sh (DMG)
.github/workflows/   release.yml publica zip y DMG al etiquetar vX.Y.Z
Resources/           icono y fondo del DMG
docs/                plan de implementación
```

| Módulo | Responsabilidad |
| --- | --- |
| `CellarCore` | `InstalledPackage`, `PackageUpgrade`, `PackageOrdering`, `AppUpdateFeed`, `BinaryLocator`, `ProcessCommandRunner` |
| `CellarProviders` | un `PackageProvider` por gestor; `CurlCatalog` para los instaladores |
| `CurlbrewApp` | `RootView` (sidebar), `ProviderBrowser`, `InstallerBrowser`, `AppModel` (estado y operaciones) |

## El DMG

`make dmg` compila, firma y empaqueta `dist/Curlbrew-<versión>.dmg` con [create-dmg](https://github.com/create-dmg/create-dmg). El DMG abre una ventana con el icono de la app y un enlace a `/Applications`: se arrastra uno sobre otro y queda instalada. El fondo es `Resources/dmg-background.png` (1320×840, o sea 660×420 a 2x).

Para que abra sin el aviso de Gatekeeper haría falta un certificado Developer ID y notarización con `notarytool`.

## Créditos

El icono es el yin-yang de [Icons8](https://icons8.com), en `Resources/AppIcon.png`.

## Licencia

MIT. Ver [LICENSE](LICENSE).
