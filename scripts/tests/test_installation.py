import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_exam", ROOT / "scripts/prepare-exam.py")
exam = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exam)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="localmenu-install-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        TEST_LOG=str(self.root / "commands.log"), TEST_BINARY_DIR=str(self.root / "compiled"))
        Path(self.env["TEST_BINARY_DIR"]).mkdir()
        executable = Path(self.env["TEST_BINARY_DIR"]) / "LocalMenu"
        executable.write_text("test executable")
        executable.chmod(0o755)
        self.mock("uname", '[[ "$1" == -s ]] && echo Darwin || echo arm64')
        self.mock("sw_vers", 'echo 14.7')
        self.mock("sysctl", '[[ "$2" == hw.memsize ]] && echo 17179869184 || echo 1')
        self.mock("swift", '''
if [[ "$1" == --version ]]; then echo 'Apple Swift version 6.2.1'; exit 0; fi
printf 'swift %s\\n' "$*" >> "$TEST_LOG"
[[ "${TEST_BUILD_FAIL:-0}" == 0 ]] || exit 2
[[ "$*" != *--show-bin-path* ]] || echo "$TEST_BINARY_DIR"
''')
        for tool in ("codesign", "lipo", "git"):
            self.mock(tool, 'printf "%s %s\\n" "$(basename "$0")" "$*" >> "$TEST_LOG"')
        self.mock("ollama", 'printf "ollama %s\\n" "$*" >> "$TEST_LOG"')
        self.mock("curl", '''
output=""; previous=""
for arg in "$@"; do [[ "$previous" != -o ]] || output="$arg"; previous="$arg"; done
case "$*" in
 *api/version*) printf '{"version":"0.40.5"}' > "$output" ;;
 *api/chat*) printf '{"message":{"tool_calls":[{"function":{"name":"search_documents"}}]}}' > "$output" ;;
 *) echo 'Network forbidden in test' >&2; exit 3 ;;
esac
''')

    def mock(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -e\n" + body + "\n")
        path.chmod(0o755)

    def helper(self, expression):
        return subprocess.run(["/bin/bash", "-c", 'source "$1"; ' + expression,
                               "test", str(ROOT / "scripts/platform.sh")], env=self.env, text=True, capture_output=True)

    def project(self):
        project = self.root / "project with spaces"
        for directory in ("scripts", "Resources"):
            shutil.copytree(ROOT / directory, project / directory, ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copy(ROOT / "Package.swift", project / "Package.swift")
        return project

    def test_profiles_and_rejected_memory(self):
        for gib, expected in ((8, "4b"), (16, "4b"), (24, "9b"), (36, "9b")):
            with self.subTest(gib=gib):
                result = self.helper(f"model_for_memory {gib * 1024**3}")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "qwen3.5:" + expected)
        for value in ("0", "4294967296", "invalid"):
            self.assertNotEqual(self.helper("model_for_memory " + value).returncode, 0)

    def test_m1_sonoma_swift62_preflight(self):
        result = self.helper('check_hardware && check_build_tools && echo "$LOCALMENU_MODEL"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "qwen3.5:4b")

    def test_rosetta_relaunch_preserves_absolute_script_path_and_arguments(self):
        self.mock("uname", "echo x86_64")
        result = self.helper('exec() { printf "<%s>\\n" "$@"; }; ensure_native_shell "/tmp/path with spaces/runtime.sh" setup')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["</usr/bin/arch>", "<-arm64>", "</bin/bash>",
                                                     "</tmp/path with spaces/runtime.sh>", "<setup>"])

    def test_old_macos_and_compiler_fail_early(self):
        self.mock("sw_vers", "echo 13.7")
        self.assertNotEqual(self.helper("check_hardware").returncode, 0)
        self.mock("swift", "echo 'Apple Swift version 6.1.2'")
        self.assertNotEqual(self.helper("check_build_tools").returncode, 0)

    def test_native_arm64_installation_and_runtime_probe(self):
        project = self.project()
        result = subprocess.run(["/bin/bash", str(project / "scripts/install.sh")], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        app = self.home / "Applications/LocalMenu.app"
        self.assertTrue((app / "Contents/MacOS/LocalMenu").is_file())
        self.assertTrue((app / "Contents/Resources/runtime.sh").is_file())
        self.assertTrue((self.home / "Applications/LocalMenu.command").is_file())
        commands = Path(self.env["TEST_LOG"]).read_text()
        self.assertIn("swift build -c release --arch arm64", commands)
        self.assertIn("lipo -verify_arch arm64", commands)
        self.assertIn("ollama cp qwen3.5:4b localmenu-assistant", commands)

    def test_compile_failure_preserves_installed_app(self):
        project = self.project()
        executable = self.home / "Applications/LocalMenu.app/Contents/MacOS/LocalMenu"
        executable.parent.mkdir(parents=True)
        executable.write_text("previous installation")
        self.env["TEST_BUILD_FAIL"] = "1"
        result = subprocess.run(["/bin/bash", str(project / "scripts/install.sh")], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(executable.read_text(), "previous installation")
        self.assertNotIn("ollama", Path(self.env["TEST_LOG"]).read_text())

    def test_rejects_non_https_repository(self):
        result = subprocess.run(["/bin/bash", str(ROOT / "scripts/install.sh"), "http://example.com/repo.git"],
                                env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / "Applications/LocalMenu.app").exists())


class ExamLabTests(unittest.TestCase):
    def test_real_aac_and_classic_profiles_have_recovery_and_no_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = exam.prepare("http://127.0.0.1:8765", directory)
            configs = [plistlib.loads(path.read_bytes()) for path in paths]
        self.assertEqual([config["lockdownModePolicy"] for config in configs], [2, 1])
        for config in configs:
            self.assertTrue(config["allowQuit"])
            self.assertEqual(config["sebConfigPurpose"], 0)
            self.assertEqual(len(config["hashedQuitPassword"]), 64)
            self.assertEqual(config["quitURL"], "http://127.0.0.1:8765/quit.html")
            self.assertFalse(config["allowVirtualMachine"])
            self.assertFalse(config["allowScreenCapture"])
            self.assertFalse(config["enableScreenProctoring"])
            self.assertIn("LocalMenu", [process["executable"] for process in config["prohibitedProcesses"]])
            self.assertTrue(all(not process["strongKill"] for process in config["prohibitedProcesses"]))

    def test_invalid_exam_urls(self):
        for url in ("file:///etc/passwd", "https://user:pass@example.com", "https://example.com/#fragment",
                    "https://example.com/?token=secret", "https://example.com:99999", "https://example.com/white space"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                exam.exam_base_url(url)

    def test_subject_is_served_without_sources_or_configuration(self):
        handler = functools.partial(SimpleHTTPRequestHandler, directory=str(ROOT / "exam-lab/web"))
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            with urlopen(base + "/", timeout=5) as response:
                self.assertIn("Examen blanc", response.read().decode())
            with urlopen(base + "/quit.html", timeout=5) as response:
                self.assertEqual(response.status, 200)
            for path in ("/materials/notes.txt", "/%2e%2e/materials/notes.txt", "/aac-strict.seb"):
                with self.subTest(path=path), self.assertRaises(HTTPError) as caught:
                    urlopen(base + path, timeout=5)
                self.assertEqual(caught.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
