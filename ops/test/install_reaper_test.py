"""Check reaper installation without starting launchd jobs or Mix processes."""

import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "requires macOS plutil")
class InstallReaperTest(unittest.TestCase):
    """Exercise path rendering with isolated HOME and mocked service commands."""

    def test_installer_renders_local_paths_without_running_mix(self):
        """Render paths containing spaces and XML metacharacters correctly."""
        build = ROOT / "_build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="reaper-install-", dir=build) as directory:
            base = Path(directory)
            checkout = base / "checkout & spaces"
            home = base / "home & spaces"
            tools = base / "tool chain"
            source = checkout / "ops" / "launchd"
            source.mkdir(parents=True)
            home.mkdir()
            tools.mkdir()
            shutil.copy2(ROOT / "ops/install-reaper.sh", checkout / "ops/install-reaper.sh")
            shutil.copy2(
                ROOT / "ops/launchd/com.veritas.reaper.plist",
                source / "com.veritas.reaper.plist",
            )
            mix = tools / "mix"
            mix.write_text("#!/bin/sh\nexit 97\n", encoding="utf-8")
            mix.chmod(0o755)
            launchctl = tools / "launchctl"
            launchctl.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$1" >> "$HOME/launchctl.calls"\n',
                encoding="utf-8",
            )
            launchctl.chmod(0o755)
            path = f"{tools}:/usr/bin:/bin:/usr/sbin:/sbin"
            env = dict(os.environ, HOME=str(home), PATH=path, VERITAS_KEEP_PORTS="9123,8010")
            subprocess.run(
                ["/bin/bash", str(checkout / "ops/install-reaper.sh")],
                env=env,
                check=True,
                capture_output=True,
                text=True,
                timeout=15,
            )
            installed = home / "Library/LaunchAgents/com.veritas.reaper.plist"
            with installed.open("rb") as stream:
                plist = plistlib.load(stream)
            self.assertEqual(plist["ProgramArguments"], [str(mix), "veritas.reap", "--go"])
            self.assertEqual(plist["WorkingDirectory"], str(checkout))
            self.assertEqual(plist["EnvironmentVariables"]["PATH"], path)
            self.assertEqual(plist["EnvironmentVariables"]["VERITAS_KEEP_PORTS"], "9123,8010")
            self.assertEqual(plist["StandardOutPath"], str(checkout / "var/log/reaper.log"))
            self.assertEqual(plist["StandardErrorPath"], str(checkout / "var/log/reaper.err.log"))
            self.assertFalse(plist["RunAtLoad"])
            self.assertEqual(plist["StartInterval"], 300)
            self.assertEqual(
                (home / "launchctl.calls").read_text().splitlines(),
                ["bootout", "bootstrap", "enable"],
            )


if __name__ == "__main__":
    unittest.main()
