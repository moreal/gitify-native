#!/usr/bin/env python3
from pathlib import Path
import os
import stat
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/generate-sparkle-appcast.sh"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class SparkleAppcastScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)
        self.zip = self.dir / "Gitify-1.2.3.zip"
        self.zip.write_bytes(b"zip fixture")
        self.output = self.dir / "appcast.xml"
        self.args_file = self.dir / "args.txt"
        self.stdin_file = self.dir / "stdin.txt"
        self.generator = self.dir / "fake-generate-appcast"
        self.generator.write_text(
            """#!/usr/bin/env python3
from pathlib import Path
import os
import sys

Path(os.environ["FAKE_ARGS_FILE"]).write_text("\\n".join(sys.argv[1:]))
Path(os.environ["FAKE_STDIN_FILE"]).write_text(sys.stdin.read())
staging = Path(sys.argv[-1])
mode = os.environ.get("FAKE_MODE", "valid")
url = (
    "https://example.invalid/Gitify-1.2.3.zip"
    if mode == "wrong-url"
    else "https://github.com/moreal/gitify-native/releases/download/"
         "v1.2.3/Gitify-1.2.3.zip"
)
signature = "" if mode == "unsigned" else ' sparkle:edSignature="test-signature"'
(staging / "appcast.xml").write_text(f'''<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item>
<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
<enclosure url="{url}"{signature} length="1" type="application/octet-stream" />
</item></channel></rss>''')
"""
        )
        self.generator.chmod(self.generator.stat().st_mode | stat.S_IXUSR)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_script(
        self,
        *,
        mode: str = "valid",
        include_key: bool = True,
        fail_final_move: bool = False,
    ):
        env = os.environ.copy()
        env.update({
            "SPARKLE_GENERATE_APPCAST": str(self.generator),
            "FAKE_ARGS_FILE": str(self.args_file),
            "FAKE_STDIN_FILE": str(self.stdin_file),
            "FAKE_MODE": mode,
        })
        if include_key:
            env["SPARKLE_ED_PRIVATE_KEY"] = "private-test-key"
        else:
            env.pop("SPARKLE_ED_PRIVATE_KEY", None)
        if fail_final_move:
            fake_bin = self.dir / "fake-bin"
            fake_bin.mkdir()
            fake_mv = fake_bin / "mv"
            fake_mv.write_text("#!/bin/sh\nexit 1\n")
            fake_mv.chmod(fake_mv.stat().st_mode | stat.S_IXUSR)
            env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
        return subprocess.run(
            [str(SCRIPT), str(self.zip), "1.2.3", str(self.output)],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
        )

    def test_generates_signed_appcast_with_versioned_github_url(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        root = ET.parse(self.output).getroot()
        enclosure = root.find("./channel/item/enclosure")
        self.assertIsNotNone(enclosure)
        self.assertEqual(
            enclosure.attrib["url"],
            "https://github.com/moreal/gitify-native/releases/download/"
            "v1.2.3/Gitify-1.2.3.zip",
        )
        self.assertEqual(
            enclosure.attrib[f"{{{SPARKLE}}}edSignature"],
            "test-signature",
        )
        self.assertIn("--ed-key-file\n-", self.args_file.read_text())
        self.assertEqual(self.stdin_file.read_text(), "private-test-key")

    def test_rejects_missing_private_key(self) -> None:
        result = self.run_script(include_key=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY is required", result.stderr)

    def test_rejects_unsigned_generated_appcast(self) -> None:
        result = self.run_script(mode="unsigned")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing EdDSA signature", result.stderr)
        self.assertNotIn("private-test-key", result.stdout + result.stderr)

    def test_rejects_wrong_enclosure_url(self) -> None:
        result = self.run_script(mode="wrong-url")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected enclosure URL", result.stderr)

    def test_removes_temporary_output_when_final_move_fails(self) -> None:
        result = self.run_script(fail_final_move=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.dir.glob(".appcast.*")), [])


if __name__ == "__main__":
    unittest.main()
