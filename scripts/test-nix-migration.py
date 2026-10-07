"""Execute the app's migration against isolated receipts and fake OS commands."""
import json, os, pathlib, subprocess, tempfile, unittest
APP = "Cochlea"
SLUG = "cochlea"
SCRIPT = pathlib.Path(__file__).with_name("migrate-homebrew.sh")

class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.prefix = self.root / "brew"
        self.metadata = self.prefix / "Caskroom" / SLUG / ".metadata"
        self.metadata.mkdir(parents=True)
        self.receipt = self.metadata / "INSTALL_RECEIPT.json"
        self.value = {"source": {"tap": "alexjmiller5/tap"}, "uninstall_flight_blocks": False,
                      "uninstall_artifacts": [{"app": [APP + ".app"]}]}
        self.destination = self.root / "Nix Apps" / (APP + ".app")
        self.source = self.root / "package" / (APP + ".app")
        self.apps = self.root / "Applications"
        self.apps.mkdir()
        for bundle in [self.source, self.destination]:
            (bundle / "Contents/_CodeSignature").mkdir(parents=True)
            (bundle / "Contents/_CodeSignature/CodeResources").write_text("signed bytes")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.marker = self.root / "calls"
        self.env = dict(os.environ, PATH=str(self.bin)+":"+os.environ["PATH"],
                        CALLS=str(self.marker), RECEIPT=str(self.receipt), RUNNING="1", SIGNATURE="0")
        self.command("id", "echo 501")
        self.command("pgrep", 'exit "$RUNNING"')
        self.command("codesign", 'exit "$SIGNATURE"')
        self.command("brew", 'printf "%s\n" "$*" >> "$CALLS"; /bin/rm "$RECEIPT"')
        (self.prefix / "bin").mkdir()
        (self.prefix / "bin/brew").symlink_to(self.bin / "brew")
        self.write_receipt()

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def write_receipt(self): self.receipt.write_text(json.dumps(self.value))

    def run_script(self, phase="preflight", enabled="1"):
        return subprocess.run(["bash", str(SCRIPT), phase, str(self.prefix), str(self.source),
                               str(self.destination), enabled, str(self.apps)],
                              env=self.env, capture_output=True, text=True)

    def test_preflight_never_uninstalls(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertTrue(self.receipt.exists())

    def test_migration_uses_only_exact_non_zap_cask(self):
        result = self.run_script("migrate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker.read_text().strip(), "uninstall --cask alexjmiller5/tap/"+SLUG)
        self.assertFalse(self.receipt.exists())

    def test_disabled_migration_rejects_existing_cask(self):
        self.assertNotEqual(self.run_script(enabled="0").returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_unknown_receipt_or_hooks_never_uninstall(self):
        for key, value in [("uninstall_flight_blocks", True),
                           ("uninstall_artifacts", [{"delete": ["data"]}]),
                           ("source", {"tap": "unknown/tap"})]:
            with self.subTest(key=key):
                old = self.value[key]; self.value[key] = value; self.write_receipt()
                self.assertNotEqual(self.run_script("migrate").returncode, 0)
                self.assertFalse(self.marker.exists())
                self.value[key] = old

    def test_missing_malformed_receipt_fails_closed(self):
        for content in [None, "{", "null"]:
            with self.subTest(content=content):
                if content is None: self.receipt.unlink(missing_ok=True)
                else: self.receipt.write_text(content)
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assertFalse(self.marker.exists())

    def test_running_or_unknown_process_status_fails_before_publication(self):
        for status in ["0", "2"]:
            self.env["RUNNING"] = status
            self.assertNotEqual(self.run_script().returncode, 0)
            self.assertFalse(self.marker.exists())

    def test_new_bundle_must_be_present_signed_and_match_package(self):
        for failure in ["missing", "signature", "changed"]:
            with self.subTest(failure=failure):
                manifest = self.destination / "Contents/_CodeSignature/CodeResources"
                if failure == "missing": manifest.unlink()
                if failure == "signature": self.env["SIGNATURE"] = "1"
                if failure == "changed": manifest.write_text("different")
                self.assertNotEqual(self.run_script("migrate").returncode, 0)
                self.assertFalse(self.marker.exists())
                manifest.write_text("signed bytes"); self.env["SIGNATURE"] = "0"

    def test_clean_repeated_activation_is_a_noop(self):
        self.receipt.unlink(); self.metadata.rmdir(); self.metadata.parent.rmdir()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script("migrate").returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_orphan_application_is_not_silently_adopted(self):
        self.receipt.unlink(); self.metadata.rmdir(); self.metadata.parent.rmdir()
        (self.apps / (APP + ".app")).mkdir()
        self.assertNotEqual(self.run_script().returncode, 0)

if __name__ == "__main__": unittest.main()
