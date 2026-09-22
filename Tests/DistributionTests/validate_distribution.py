#!/usr/bin/env python3
from pathlib import Path
import base64
import plistlib
import re
import struct
import unittest
from html.parser import HTMLParser


ROOT = Path(__file__).resolve().parents[2]
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
README = ROOT / "README.md"
INFO_PLIST = ROOT / "Sources/Info.plist"
PROJECT_SPEC = ROOT / "project.yml"
STABLE_DMG_URL = (
    "https://github.com/moreal/gitify-native/releases/latest/download/Gitify.dmg"
)
SITE_ROOT = ROOT / "docs/site"
INDEX = SITE_ROOT / "index.html"
STYLES = SITE_ROOT / "styles.css"
APP_ICON = SITE_ROOT / "app-icon.png"
APP_SCREENSHOT = SITE_ROOT / "assets/gitify-popover.png"
PAGES_WORKFLOW = ROOT / ".github/workflows/pages.yml"
SCREENSHOT_EXPORT_SCRIPT = ROOT / "scripts/export-landing-screenshot.sh"
LANDING_SCREENSHOT_RENDERER = ROOT / "Sources/UI/LandingScreenshotRenderer.swift"
NOTIFICATIONS_LIST_VIEW = ROOT / "Sources/UI/NotificationsListView.swift"


class LandingPageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.main_count = 0
        self.image_alts: list[str] = []
        self.links: set[str] = set()
        self.stylesheets: set[str] = set()
        self.script_count = 0
        self.feature_icons: dict[str, bool] = {}
        self._article_title = ""
        self._article_has_svg_icon = False
        self._in_article = False
        self._in_article_title = False
        self._in_feature_icon = False

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
        elif tag == "article":
            self._in_article = True
            self._article_title = ""
            self._article_has_svg_icon = False
        elif self._in_article and tag == "h3":
            self._in_article_title = True
        elif self._in_article and tag == "span" and "feature-icon" in (
            attributes.get("class") or ""
        ).split():
            self._in_feature_icon = True
        elif self._in_feature_icon and tag == "svg":
            self._article_has_svg_icon = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "h3":
            self._in_article_title = False
        elif tag == "span":
            self._in_feature_icon = False
        elif tag == "article" and self._in_article:
            self.feature_icons[self._article_title.strip()] = self._article_has_svg_icon
            self._in_article = False

    def handle_data(self, data: str) -> None:
        if self._in_article_title:
            self._article_title += data


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

    def test_sparkle_configuration_is_publishable(self) -> None:
        info = plistlib.loads(INFO_PLIST.read_bytes())
        self.assertEqual(
            info["SUFeedURL"],
            "https://github.com/moreal/gitify-native/releases/latest/download/appcast.xml",
        )
        self.assertIs(info["SUEnableAutomaticChecks"], True)
        self.assertIs(info["SUAutomaticallyUpdate"], False)
        self.assertEqual(
            len(base64.b64decode(info["SUPublicEDKey"], validate=True)),
            32,
        )
        project = PROJECT_SPEC.read_text()
        self.assertIn("https://github.com/sparkle-project/Sparkle", project)
        self.assertIn("exactVersion: 2.10.0", project)

    def test_release_publishes_signed_sparkle_appcast(self) -> None:
        self.assertIn("scripts/generate-sparkle-appcast.sh", self.release)
        self.assertIn("secrets.SPARKLE_ED_PRIVATE_KEY", self.release)
        self.assertIn("*/Sparkle/bin/generate_appcast", self.release)
        self.assertIn('"appcast.xml"', self.release)

    def test_release_resigns_embedded_sparkle_code_before_notarization(self) -> None:
        sign_step = self.release.index("- name: Re-sign embedded Sparkle components")
        notarize_step = self.release.index("- name: Notarize and staple")
        self.assertLess(sign_step, notarize_step)
        for component in (
            '"$SPARKLE/Versions/Current/Autoupdate"',
            '"$SPARKLE/Versions/Current/Updater.app"',
            '"$SPARKLE/Versions/Current/XPCServices/Downloader.xpc"',
            '"$SPARKLE/Versions/Current/XPCServices/Installer.xpc"',
            '"$SPARKLE"',
            '"$APP"',
        ):
            self.assertIn(component, self.release)
        self.assertIn("--options runtime", self.release)
        self.assertIn("--timestamp", self.release)
        self.assertIn(
            "--preserve-metadata=identifier,entitlements", self.release
        )
        self.assertIn('codesign --verify --deep --strict "$APP"', self.release)

    def test_prerelease_tags_do_not_replace_stable_sparkle_feed(self) -> None:
        self.assertIn('echo "prerelease=true" >> "$GITHUB_OUTPUT"', self.release)
        self.assertIn('RELEASE_ARGS+=(--prerelease)', self.release)
        self.assertIn('"${RELEASE_ARGS[@]}"', self.release)

    def test_readme_links_to_latest_dmg(self) -> None:
        self.assertIn(STABLE_DMG_URL, self.readme)


class LandingPageTests(unittest.TestCase):
    def test_landing_page_has_download_content_and_local_assets(self) -> None:
        self.assertTrue(INDEX.exists(), "landing page index.html must exist")
        self.assertTrue(STYLES.exists(), "landing page styles.css must exist")
        self.assertTrue(APP_ICON.exists(), "landing page app icon must exist")
        self.assertTrue(APP_SCREENSHOT.exists(), "actual app screenshot must exist")

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
        self.assertIn("assets/gitify-popover.png", html)
        self.assertIn("Actual Gitify Native UI shown with deterministic test data", html)
        self.assertNotIn('class="app-demo"', html)
        self.assertEqual(parser.script_count, 0)
        self.assertEqual(APP_ICON.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
        screenshot = APP_SCREENSHOT.read_bytes()
        self.assertEqual(screenshot[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack(">II", screenshot[16:24]), (1680, 2240))

    def test_styles_cover_focus_touch_dark_mode_and_reduced_motion(self) -> None:
        self.assertTrue(STYLES.exists(), "landing page styles.css must exist")
        css = STYLES.read_text()
        self.assertIn(":focus-visible", css)
        self.assertIn("min-height: 44px", css)
        self.assertIn("@media (hover: hover) and (pointer: fine)", css)
        self.assertIn("@media (prefers-color-scheme: dark)", css)
        self.assertIn("@media (prefers-reduced-motion: reduce)", css)
        self.assertNotIn("transition: all", css)

    def test_install_step_numbers_use_the_page_color(self) -> None:
        css = STYLES.read_text()
        step_number_rule = re.search(
            r"\.install-steps li > span\s*\{(?P<declarations>[^}]*)\}", css
        )

        self.assertIsNotNone(step_number_rule)
        self.assertRegex(
            step_number_rule.group("declarations"), r"color:\s*var\(--page\);"
        )

    def test_native_alerts_uses_a_vector_icon(self) -> None:
        parser = LandingPageParser()
        parser.feed(INDEX.read_text())

        self.assertIn("Native alerts", parser.feature_icons)
        self.assertTrue(parser.feature_icons["Native alerts"])

    def test_pages_workflow_deploys_only_site_directory(self) -> None:
        self.assertTrue(PAGES_WORKFLOW.exists(), "Pages workflow must exist")
        workflow = PAGES_WORKFLOW.read_text()
        self.assertIn("actions/configure-pages@v5", workflow)
        self.assertIn("actions/upload-pages-artifact@v4", workflow)
        self.assertIn("actions/deploy-pages@v5", workflow)
        self.assertIn("runs-on: macos-15", workflow)
        self.assertIn("testCaptureLandingScreenshot", workflow)
        self.assertTrue(SCREENSHOT_EXPORT_SCRIPT.exists())
        export_script = SCREENSHOT_EXPORT_SCRIPT.read_text()
        self.assertIn("xcresulttool export attachments", export_script)
        self.assertIn("EXPECTED_PIXEL_WIDTH=1680", export_script)
        self.assertIn("EXPECTED_PIXEL_HEIGHT=2240", export_script)
        self.assertNotIn("--cropToHeightWidth", export_script)
        self.assertTrue(LANDING_SCREENSHOT_RENDERER.exists())
        renderer = LANDING_SCREENSHOT_RENDERER.read_text()
        self.assertIn("ImageRenderer", renderer)
        self.assertIn("renderer.scale = 4", renderer)
        self.assertNotIn("cacheDisplay", renderer)
        self.assertIn("pixelsWide == 1680", renderer)
        self.assertIn("pixelsHigh == 2240", renderer)
        notifications_view = NOTIFICATIONS_LIST_VIEW.read_text()
        self.assertIn("if UITestMock.isLandingScreenshot", notifications_view)
        self.assertIn("VStack(spacing: 0)", notifications_view)
        self.assertIn("path: docs/site", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("pages: write", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertIn("if: github.ref == 'refs/heads/main'", workflow)


if __name__ == "__main__":
    unittest.main()
