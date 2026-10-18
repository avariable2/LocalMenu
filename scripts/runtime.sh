#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"
source ./platform.sh
ensure_native_shell "$PWD/runtime.sh" "$@"

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 && ( "$1" == start || "$1" == setup ) ]] || fail "Usage : bash runtime.sh start|setup"
[[ "$(uname -s)" == Darwin ]] || fail "macOS est requis."
if [[ "$1" == setup ]]; then check_hardware; fi

ollama=""
for candidate in "$(command -v ollama || true)" \
    "$HOME/Applications/LocalMenuRuntime/Ollama.app/Contents/Resources/ollama" \
    "$HOME/Applications/Ollama.app/Contents/Resources/ollama" \
    /Applications/Ollama.app/Contents/Resources/ollama; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then ollama="$candidate"; break; fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [[ -z "$ollama" ]]; then
    [[ "$1" == setup ]] || fail "Ollama est absent. Relancez scripts/install.sh."
    directory="$HOME/Applications/LocalMenuRuntime"
    [[ ! -e "$directory/Ollama.app" ]] || fail "Une installation Ollama incomplète existe dans $directory. Vérifiez-la avant de réinstaller."
    printf 'Téléchargement d’Ollama 0.40.5 (éditeur officiel, somme SHA-256 vérifiée)…\n'
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 2 \
        'https://github.com/ollama/ollama/releases/download/v0.40.5/Ollama-darwin.zip' -o "$work/ollama.zip"
    printf '%s  %s\n' 'b07392350465d52b24cf23d6cfba61093fda312452b60d41867b4216ede6c8b2' "$work/ollama.zip" | shasum -a 256 -c -
    ditto -x -k "$work/ollama.zip" "$work/unpacked"
    codesign --verify --deep --strict "$work/unpacked/Ollama.app"
    spctl --assess --type execute "$work/unpacked/Ollama.app"
    lipo "$work/unpacked/Ollama.app/Contents/Resources/ollama" -verify_arch arm64
    mkdir -p "$directory"
    mv "$work/unpacked/Ollama.app" "$directory/Ollama.app"
    ollama="$directory/Ollama.app/Contents/Resources/ollama"
fi

export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_NO_CLOUD=1
server_ready() {
    curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:11434/api/version \
        -o "$work/version.json" && plutil -extract version raw -o - "$work/version.json" >/dev/null 2>&1
}
if ! server_ready; then
    mkdir -p "$HOME/Library/Logs/LocalMenu"
    printf 'Démarrage du serveur Ollama local (pas de démarrage automatique à la connexion).\n'
    nohup "$ollama" serve >>"$HOME/Library/Logs/LocalMenu/ollama.log" 2>&1 < /dev/null &
    for ((attempt = 0; attempt < 30; attempt++)); do
        server_ready && break
        sleep 1
    done
    server_ready || fail "Ollama ne démarre pas. Consultez ~/Library/Logs/LocalMenu/ollama.log."
else
    printf 'Serveur Ollama existant conservé ; sa configuration globale n’est pas modifiée.\n'
fi
[[ "$1" == setup ]] || exit 0
printf 'Modèle adapté à la mémoire détectée : %s\n' "$LOCALMENU_MODEL"
if ! "$ollama" show "$LOCALMENU_MODEL" >/dev/null 2>&1; then
    free_kb="$(df -Pk "$HOME" | awk 'END {print $4}')"
    [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb >= 12 * 1024 * 1024 )) || fail "12 Go libres sont nécessaires pour télécharger le modèle."
    "$ollama" pull "$LOCALMENU_MODEL"
fi
"$ollama" cp "$LOCALMENU_MODEL" localmenu-assistant

# Check native tool calling before reporting a working installation.
curl --noproxy '*' --fail --silent --show-error --max-time 300 http://127.0.0.1:11434/api/chat \
    -H 'Content-Type: application/json' -d '{"model":"localmenu-assistant","stream":false,"think":false,"options":{"temperature":0,"num_ctx":16384},"messages":[{"role":"user","content":"Appelle search_documents avec query LOCALMENU_CHECK_73. Ne réponds pas sans cet outil."}],"tools":[{"type":"function","function":{"name":"search_documents","description":"Chercher un document par référence.","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}]}' \
    -o "$work/check.json"
tool="$(plutil -extract message.tool_calls.0.function.name raw -o - "$work/check.json" 2>/dev/null || true)"
[[ "$tool" == search_documents ]] || fail "Le modèle n'a pas appelé l'outil de contrôle. Installation du moteur non validée."
printf 'Moteur local prêt ; appel d’outil vérifié. Alias réservé à l’app : localmenu-assistant.\n'
