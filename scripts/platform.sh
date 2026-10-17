#!/bin/bash

platform_fail() { printf '%s\n' "$*" >&2; return 1; }

ensure_native_shell() {
    local script="$1"
    shift
    if [[ "$(uname -m)" == x86_64 && "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
        exec /usr/bin/arch -arm64 /bin/bash "$script" "$@"
    fi
}

model_for_memory() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || { platform_fail "Mémoire physique illisible."; return 1; }
    (( bytes >= 8 * 1024 * 1024 * 1024 )) || { platform_fail "8 Go de RAM minimum sont requis."; return 1; }
    if (( bytes >= 24 * 1024 * 1024 * 1024 )); then
        printf 'qwen3.5:9b\n'
    else
        printf 'qwen3.5:4b\n'
    fi
}

check_hardware() {
    [[ "$(uname -s)" == Darwin ]] || { platform_fail "macOS est requis."; return 1; }
    [[ "$(uname -m)" == arm64 ]] || { platform_fail "Utilisez un Mac Apple Silicon et un Terminal natif, sans Rosetta."; return 1; }
    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 14 )) || { platform_fail "macOS 14 minimum est requis."; return 1; }
    local memory
    memory="$(sysctl -n hw.memsize)"
    LOCALMENU_MODEL="$(model_for_memory "$memory")" || return 1
    if (( memory < 16 * 1024 * 1024 * 1024 )); then
        printf 'Attention : 8 Go de RAM, fermez les applications lourdes. Les performances sur M1 8 Go ne sont pas encore mesurées.\n' >&2
    fi
}

check_build_tools() {
    xcode-select -p >/dev/null 2>&1 || { platform_fail "Installez les outils Apple avec xcode-select --install, puis sélectionnez une toolchain Swift 6.2 minimum."; return 1; }
    local tool version
    for tool in swift git codesign ditto lipo; do
        command -v "$tool" >/dev/null || { platform_fail "Outil manquant : $tool. Installez Xcode/Command Line Tools avec Swift 6.2 minimum."; return 1; }
    done
    version="$(swift --version)" || return 1
    if [[ "$version" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
        (( BASH_REMATCH[1] > 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] >= 2) )) || {
            platform_fail "Swift 6.2 minimum requis. Mettez à jour Xcode/Command Line Tools et macOS si nécessaire."
            return 1
        }
    else
        platform_fail "Impossible de vérifier la version de Swift."
        return 1
    fi
}
