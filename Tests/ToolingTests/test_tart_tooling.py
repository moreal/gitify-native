#!/usr/bin/env python3
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUN_SCRIPT = ROOT / "scripts/run-in-tart.sh"
README = ROOT / "README.md"
AGENT_INSTRUCTIONS = ROOT / "AGENTS.md"


class TartToolingTests(unittest.TestCase):
    def test_runner_uses_pinned_xcode_image_without_a_custom_build(self) -> None:
        runner = RUN_SCRIPT.read_text()

        self.assertIn("macos-sequoia-xcode@sha256:", runner)
        self.assertIn("xcodegen generate", runner)
        self.assertIn("TART_NO_AUTO_PRUNE=1 tart clone", runner)
        self.assertIn("tart clone", runner)
        self.assertIn("--no-graphics", runner)
        self.assertIn("--no-audio", runner)
        self.assertIn("--no-clipboard", runner)
        self.assertIn("tart exec", runner)
        self.assertIn("tart stop", runner)
        self.assertIn("tart delete", runner)
        self.assertIn(":ro", runner)

    def test_commands_offer_help_without_starting_a_vm(self) -> None:
        result = subprocess.run(
            [str(RUN_SCRIPT), "--help"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)

        readme = README.read_text()
        self.assertIn("scripts/run-in-tart.sh test", readme)
        self.assertIn("scripts/run-in-tart.sh screenshot", readme)
        self.assertNotIn("scripts/build-tart-image.sh", readme)

    def test_agents_are_directed_to_keep_ui_automation_off_the_host(self) -> None:
        instructions = AGENT_INSTRUCTIONS.read_text()

        self.assertIn("scripts/run-in-tart.sh", instructions)
        self.assertIn("must not run macOS UI tests directly on the host", instructions)


if __name__ == "__main__":
    unittest.main()
