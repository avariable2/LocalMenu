#!/usr/bin/env python3
"""Prepare an administrator-controlled SEB lab. Never launches lockdown."""
import argparse
import hashlib
from pathlib import Path
import plistlib
from urllib.parse import urlsplit, urlunsplit

LAB_PASSWORD = "LocalMenuLab2026"


def exam_base_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or any(character.isspace() for character in value)):
        raise ValueError("URL HTTP(S) sans identifiants, paramètres ou fragment requise")
    _ = parsed.port  # Reject malformed/out-of-range ports.
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/") + "/", "", ""))


def prepare(url, output):
    base = exam_base_url(url)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    password_hash = hashlib.sha256(LAB_PASSWORD.encode("ascii")).hexdigest().upper()
    common = {
        "sebConfigPurpose": 0,  # Exam session, not persistent client configuration.
        "startURL": base,
        "quitURL": base + "quit.html",
        "quitURLConfirm": True,
        "allowQuit": True,
        "hashedQuitPassword": password_hash,
        "hashedAdminPassword": password_hash,
        "allowPreferencesWindow": True,  # Recovery in this lab only.
        "allowSwitchToApplications": False,
        "allowScreenCapture": False,
        "allowWindowCapture": False,
        "allowScreenSharing": False,
        "allowBrowserScreenCapture": False,
        "enableScreenProctoring": False,
        "allowVirtualMachine": False,
        "prohibitedProcesses": [
            {"active": True, "os": 0, "executable": "LocalMenu", "identifier": "local.localmenu.app",
             "strongKill": False, "ignoreInAAC": False},
            {"active": True, "os": 0, "executable": "ollama", "strongKill": False, "ignoreInAAC": False},
        ],
    }
    paths = []
    for name, policy in (("aac-strict", 2), ("classic-prohibited", 1)):
        path = output / (name + ".seb")
        # SEB accepts plain XML plists. These editable files are for a lab, not secure distribution.
        path.write_bytes(plistlib.dumps(dict(common, lockdownModePolicy=policy), fmt=plistlib.FMT_XML))
        paths.append(path)
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8765/", help="URL du sujet, idéalement servi depuis un second Mac")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        paths = prepare(args.url, root / "dist" / "exam-lab")
    except ValueError as error:
        parser.error(str(error))
    print("Configurations préparées, aucun verrouillage lancé.")
    for path in paths:
        print(path)
    print("Mot de passe de sortie et d’administration du laboratoire :", LAB_PASSWORD)
    print("Lire exam-lab/README.md avant d’ouvrir un .seb. Ces profils BLOQUENT LocalMenu.")
    print("Un test SEB n'est pas une validation de Respondus, d'un LMS ou d'une surveillance par webcam.")


if __name__ == "__main__":
    main()
