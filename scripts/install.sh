#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || fail "Usage : bash scripts/install.sh [URL-du-dépôt]"
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$source_dir/scripts/platform.sh"
ensure_native_shell "$source_dir/scripts/install.sh" "$@"
check_hardware
check_build_tools
work="$(mktemp -d)"
stage=""
backup=""
target="$HOME/Applications/LocalMenu.app"
cleanup() {
    if [[ -n "$backup" && -d "$backup" && ! -e "$target" ]]; then
        mv "$backup" "$target"
    fi
    [[ -z "$stage" ]] || rm -rf "$stage"
    rm -rf "$work"
}
trap cleanup EXIT

if [[ $# -eq 1 ]]; then
    [[ "$1" == https://* ]] || fail "Utilisez une URL de dépôt HTTPS de confiance."
    # Building a repository executes its code; only install repositories you trust.
    git clone --depth 1 -- "$1" "$work/repo"
    source_dir="$work/repo"
fi
[[ -f "$source_dir/Package.swift" && -f "$source_dir/scripts/build-app.sh" ]] || fail "Ce dépôt ne contient pas LocalMenu."

bash "$source_dir/scripts/build-app.sh"
codesign --verify --strict "$source_dir/dist/LocalMenu.app"
[[ -x "$source_dir/dist/LocalMenu.app/Contents/MacOS/LocalMenu" ]] || fail "Exécutable compilé introuvable."
lipo "$source_dir/dist/LocalMenu.app/Contents/MacOS/LocalMenu" -verify_arch arm64
bash "$source_dir/scripts/runtime.sh" setup

mkdir -p "$HOME/Applications"
[[ ! -L "$target" ]] || fail "Refus de remplacer un lien symbolique : $target"
if [[ -e "$target" ]]; then
    [[ -d "$target" ]] || fail "Un fichier existe déjà : $target"
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")
    [[ "$identifier" == local.localmenu.app ]] || fail "Une autre application occupe $target"
fi
stage="$(mktemp -d "$HOME/Applications/.localmenu.XXXXXX")"
ditto "$source_dir/dist/LocalMenu.app" "$stage/LocalMenu.app"
codesign --verify --strict "$stage/LocalMenu.app"
if [[ -d "$target" ]]; then
    backup="$stage/previous.app"
    mv "$target" "$backup"
fi
mv "$stage/LocalMenu.app" "$target"
backup=""

# A visible, user-controlled launcher, not a background login item.
cp "$source_dir/Resources/LocalMenu.command" "$HOME/Applications/LocalMenu.command"
chmod +x "$HOME/Applications/LocalMenu.command"
printf '\nInstallé : %s\nDouble-cliquez sur %s/Applications/LocalMenu.command pour lancer l’app.\n' "$target" "$HOME"
printf 'Ou exécutez : open "%s"\n' "$target"
printf 'Architecture arm64 vérifiée ; Ollama et le modèle local sont prêts.\n'
