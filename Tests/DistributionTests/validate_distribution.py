#!/usr/bin/env python3
from pathlib import Path
from html.parser import HTMLParser
import unittest


ROOT = Path(__file__).resolve().parents[2]
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
README = ROOT / "README.md"
STABLE_DMG_URL = (
    "https://github.com/moreal/gitify-native/releases/latest/download/Gitify.dmg"
)
SITE_ROOT = ROOT / "docs/site"
INDEX = SITE_ROOT / "index.html"
STYLES = SITE_ROOT / "styles.css"
APP_ICON = SITE_ROOT / "app-icon.png"
PAGES_WORKFLOW = ROOT / ".github/workflows/pages.yml"


class LandingPageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.main_count = 0
        self.image_alts: list[str] = []
        self.links: set[str] = set()
        self.stylesheets: set[str] = set()
        self.script_count = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "main":
            self.main_count += 1
        elif tag == "img":
            self.image_alts.append(attributes.get("alt") or "")
        elif tag == "a" and attributes.get("href"):
            self.links.add(attributes["href"] or "")
        elif tag == "link" and attributes.get("rel") == "stylesheet":
            self.stylesheets.add(attributes.get("href") or "")
        elif tag == "script":
            self.script_count += 1


class ReleaseDistributionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.release = RELEASE_WORKFLOW.read_text()
        cls.readme = README.read_text()

    def test_release_publishes_stable_verified_dmg(self) -> None:
        self.assertIn('DMG="Gitify.dmg"', self.release)
        self.assertIn('hdiutil verify "$DMG"', self.release)
        self.assertIn('test -d "$MOUNT_POINT/Gitify.app"', self.release)
        self.assertIn('test -L "$MOUNT_POINT/Applications"', self.release)
        self.assertIn('"Gitify.dmg"', self.release)
        self.assertIn('"Gitify.dmg.sha256"', self.release)
        self.assertNotIn('Gitify-$VERSION.dmg', self.release)

    def test_release_keeps_versioned_updater_zip(self) -> None:
        self.assertIn('"Gitify-$VERSION.zip"', self.release)
        self.assertIn('"Gitify-$VERSION.zip.sha256"', self.release)

    def test_readme_links_to_latest_dmg(self) -> None:
        self.assertIn(STABLE_DMG_URL, self.readme)


class LandingPageTests(unittest.TestCase):
    def test_landing_page_has_download_content_and_local_assets(self) -> None:
        self.assertTrue(INDEX.exists(), "landing page index.html must exist")
        self.assertTrue(STYLES.exists(), "landing page styles.css must exist")
        self.assertTrue(APP_ICON.exists(), "landing page app icon must exist")

        html = INDEX.read_text()
        parser = LandingPageParser()
        parser.feed(html)

        self.assertEqual(parser.main_count, 1)
        self.assertTrue(all(parser.image_alts), "every image needs alt text")
        self.assertIn(STABLE_DMG_URL, parser.links)
        self.assertIn("https://github.com/moreal/gitify-native", parser.links)
        self.assertIn("https://github.com/moreal/gitify-native/releases", parser.links)
        self.assertIn("styles.css", parser.stylesheets)
        self.assertIn("macOS 14+", html)
        self.assertEqual(parser.script_count, 0)
        self.assertEqual(APP_ICON.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")

    def test_styles_cover_focus_touch_dark_mode_and_reduced_motion(self) -> None:
        self.assertTrue(STYLES.exists(), "landing page styles.css must exist")
        css = STYLES.read_text()
        self.assertIn(":focus-visible", css)
        self.assertIn("min-height: 44px", css)
        self.assertIn("@media (hover: hover) and (pointer: fine)", css)
        self.assertIn("@media (prefers-color-scheme: dark)", css)
        self.assertIn("@media (prefers-reduced-motion: reduce)", css)
        self.assertNotIn("transition: all", css)

    def test_pages_workflow_deploys_only_site_directory(self) -> None:
        self.assertTrue(PAGES_WORKFLOW.exists(), "Pages workflow must exist")
        workflow = PAGES_WORKFLOW.read_text()
        self.assertIn("actions/configure-pages@v5", workflow)
        self.assertIn("actions/upload-pages-artifact@v4", workflow)
        self.assertIn("actions/deploy-pages@v5", workflow)
        self.assertIn("path: docs/site", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("pages: write", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertIn("if: github.ref == 'refs/heads/main'", workflow)


if __name__ == "__main__":
    unittest.main()
