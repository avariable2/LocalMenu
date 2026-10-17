#!/bin/bash
set -euo pipefail
app="$(cd "$(dirname "$0")" && pwd)/LocalMenu.app"
if [[ ! -d "$app" ]]; then
    printf 'Application introuvable : %s\nRelancez le script d’installation.\n' "$app" >&2
    exit 1
fi
bash "$app/Contents/Resources/runtime.sh" start
open "$app"
