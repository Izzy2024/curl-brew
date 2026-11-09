#!/bin/zsh
set -euo pipefail

# Empaqueta Curlbrew.app en un DMG instalable con create-dmg.
#   ./Scripts/package-dmg.sh            -> dist/Curlbrew-<version>.dmg
# Requiere: create-dmg (brew install create-dmg) y un Curlbrew.app ya firmado
# (lo produce ./Scripts/package-app.sh, o `make app`).

root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/Curlbrew.app"
dist="$root/dist"

if [[ ! -d "$app" ]]; then
  echo "no está $app; corre primero ./Scripts/package-app.sh" >&2
  exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "falta create-dmg; instálalo con: brew install create-dmg" >&2
  exit 1
fi

# La firma ad-hoc se invalida si se toca el bundle después de firmarlo.
# Sin --strict: Documents vuelve a estampar com.apple.FinderInfo en el bundle y
# --strict lo trata como detritus. Esos atributos se quitan del staging.
if ! codesign --verify "$app" >/dev/null 2>&1; then
  echo "la firma de $app no es válida; vuelve a firmarla con ./Scripts/package-app.sh" >&2
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="$dist/Curlbrew-$version.dmg"

# create-dmg copia el contenido de una carpeta de staging, no el .app suelto.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Curlbrew.app"
# Sin esto codesign rechaza el bundle al volver a firmarlo dentro del DMG.
xattr -cr "$stage/Curlbrew.app"

mkdir -p "$dist"
rm -f "$dmg"

# create-dmg sale con 2 cuando Finder no puede aplicar la disposición de iconos
# (pasa cuando no hay sesión gráfica). El DMG ya está creado y es válido.
set +e
create-dmg \
  --volname "Curlbrew" \
  --volicon "$app/Contents/Resources/AppIcon.icns" \
  --background "$root/Resources/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 420 \
  --text-size 13 \
  --icon-size 128 \
  --icon "Curlbrew.app" 180 190 \
  --hide-extension "Curlbrew.app" \
  --app-drop-link 480 190 \
  --no-internet-enable \
  --format UDZO \
  "$dmg" "$stage"
rc=$?
set -e

if [[ $rc -ne 0 && $rc -ne 2 ]]; then
  echo "create-dmg falló con estado $rc" >&2
  exit $rc
fi
if [[ ! -f "$dmg" ]]; then
  echo "create-dmg no dejó $dmg" >&2
  exit 1
fi

# Firma el DMG con la misma identidad ad-hoc para que su sello sea consistente.
codesign --force --sign - "$dmg" >/dev/null 2>&1 || true

hdiutil verify "$dmg" >/dev/null
echo "$dmg"
