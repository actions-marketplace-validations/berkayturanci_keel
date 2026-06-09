"""Release-version drift checks for public install guidance."""

from __future__ import annotations

import re
import tomllib
import unittest
from pathlib import Path

from keel import __version__

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSIONED_GIT_INSTALL_RE = re.compile(
    r'pip install "git\+https://github\.com/berkayturanci/keel@(?P<tag>v[0-9]+\.[0-9]+\.[0-9]+)"'
)


class TestReleaseDocs(unittest.TestCase):
    def test_python_package_and_project_metadata_versions_match(self):
        metadata = tomllib.loads((REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8"))

        self.assertEqual(metadata["project"]["version"], __version__)

    def test_public_git_install_examples_match_current_release_tag(self):
        expected_tag = f"v{__version__}"
        paths = [
            REPO_ROOT / "README.md",
            REPO_ROOT / "website/index.html",
            REPO_ROOT / ".github/workflows/keel-ship.yml",
        ]

        for path in paths:
            with self.subTest(path=str(path.relative_to(REPO_ROOT))):
                text = path.read_text(encoding="utf-8")
                tags = [match.group("tag") for match in VERSIONED_GIT_INSTALL_RE.finditer(text)]
                self.assertTrue(tags, f"expected at least one versioned git install in {path}")
                self.assertEqual(tags, [expected_tag])


if __name__ == "__main__":
    unittest.main()
