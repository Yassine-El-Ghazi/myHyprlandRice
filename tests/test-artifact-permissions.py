#!/usr/bin/env python3
"""Exercise artifact permissions with disposable homes and synthetic captures."""

import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
SCREENSHOTS = (
    ("dotfiles/.config/hypr/scripts/screenshot.sh", ("--instant",)),
    ("dotfiles/.config/hypr/scripts/screenshot.sh", ("--instant-area",)),
    ("dotfiles/.config/myhypr/bin/myhypr-screenshot.sh", ("fullscreen",)),
    ("dotfiles/.config/myhypr/bin/myhypr-screenshot.sh", ("area",)),
    ("dotfiles/.config/myhypr/bin/myhypr-screenshot.sh", ("window",)),
)


class PrivateArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="myhypr-private-artifacts-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir(mode=0o755)
        self.home.chmod(0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.config = self.home / ".config"
        settings = self.config / "myhypr/settings"
        settings.mkdir(parents=True)
        self.config.chmod(0o700)
        (settings.parent / "library.sh").symlink_to(
            REPO / "dotfiles/.config/myhypr/library.sh"
        )
        self.output = self.home / "Captures with spaces"
        (settings / "screenshot-folder").write_text(str(self.output))
        (settings / "screenshot-filename").write_text("shot.png")
        (settings / "screenshot-editor").write_text("unused-editor")
        self.record = self.root / "record.json"
        self.env = {
            "HOME": str(self.home), "XDG_CONFIG_HOME": str(self.config),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "TMPDIR": str(self.tmp), "PATH": f"{self.bin}:/usr/bin:/bin",
            "RECORD": str(self.record),
        }
        self.tool("grim", """import os, pathlib, sys
destination = sys.argv[-1]
if destination == '-':
    print('synthetic image')
else:
    pathlib.Path(destination).write_text('synthetic image')
sys.exit(int(os.environ.get('CAPTURE_FAILURE', '0')))
""")
        self.tool("slurp", """import os, sys
sys.exit(1) if os.environ.get('CANCEL') else print('0,0 10x10')
""")
        self.tool("hyprpicker", "import time\ntime.sleep(30)\n")
        self.tool("notify-send", "pass\n")
        self.tool("hyprctl", "print('{\"at\":[0,0],\"size\":[10,10]}')\n")
        self.tool("pacman", "print('tesseract-data-eng')\n")
        self.tool("rofi", "import sys\nsys.stdin.read()\n")
        self.tool("magick", "import sys\nsys.stdout.write(sys.stdin.read())\n")
        self.tool("tesseract", """import os, sys, time
sys.stdin.read()
if os.environ.get('OCR_WAIT'):
    open(os.environ['RECORD'] + '.ready', 'w').close()
    time.sleep(30)
print('synthetic extracted text')
sys.exit(int(os.environ.get('CAPTURE_FAILURE', '0')))
""")
        self.tool("wl-copy", """import json, os, stat, sys
record = {'mode': oct(stat.S_IMODE(os.fstat(0).st_mode)), 'text': sys.stdin.read()}
with open(os.environ['RECORD'], 'w') as stream:
    json.dump(record, stream)
""")

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/python3\n" + body)
        path.chmod(0o700)

    def run_script(self, relative, arguments=(), *, extra=None, mask=0o022):
        return subprocess.run(
            ["/bin/bash", str(REPO / relative), *arguments],
            env=self.env | (extra or {}), capture_output=True, text=True,
            umask=mask, timeout=30,
        )

    def test_ocr_keeps_private_inode_until_copy(self):
        script = "dotfiles/.config/hypr/scripts/text-extractor.sh"
        for mask in (0o022, 0o077):
            with self.subTest(umask=oct(mask)):
                result = self.run_script(script, mask=mask)
                self.assertEqual(result.returncode, 0, result.stderr)
                record = json.loads(self.record.read_text())
                self.assertEqual(record["mode"], "0o600")
                self.assertEqual(record["text"], "synthetic extracted text\n")
                self.assertEqual(list(self.tmp.iterdir()), [])

    def test_ocr_failure_and_cancel_do_not_copy_or_leave_output(self):
        for extra in ({"CANCEL": "1"}, {"CAPTURE_FAILURE": "7"}):
            with self.subTest(extra=extra):
                result = self.run_script("dotfiles/.config/hypr/scripts/text-extractor.sh",
                                         extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.record.exists())
                self.assertEqual(list(self.tmp.iterdir()), [])

    def test_ocr_termination_cleans_up_and_does_not_resume(self):
        process = subprocess.Popen(
            ["/bin/bash", str(REPO / "dotfiles/.config/hypr/scripts/text-extractor.sh")],
            env=self.env | {"OCR_WAIT": "1"}, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, umask=0o022, start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 10
            ready = Path(str(self.record) + ".ready")
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "OCR fixture did not reach processing")
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143)
            self.assertFalse(self.record.exists())
            self.assertEqual(list(self.tmp.iterdir()), [])
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_all_screenshot_modes_create_private_files(self):
        for script, arguments in SCREENSHOTS:
            for mask in (0o022, 0o077):
                with self.subTest(script=script, arguments=arguments, umask=oct(mask)):
                    shutil.rmtree(self.output, ignore_errors=True)
                    result = self.run_script(script, arguments, mask=mask)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
                    file = self.output / "shot.png"
                    self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
                    self.assertEqual(file.read_text(), "synthetic image")

    def test_screenshot_collisions_preserve_existing_files_and_links(self):
        self.output.mkdir(mode=0o755)
        self.output.chmod(0o755)
        original = self.output / "shot.png"
        target = self.root / "unrelated"
        target.write_text("original unrelated content")
        for kind in ("regular", "symlink"):
            with self.subTest(kind=kind):
                if original.exists() or original.is_symlink():
                    original.unlink()
                if kind == "regular":
                    original.write_text("original screenshot")
                    original.chmod(0o644)
                else:
                    original.symlink_to(target)
                before = set(self.output.iterdir())
                result = self.run_script(*SCREENSHOTS[0])
                self.assertEqual(result.returncode, 0, result.stderr)
                created = set(self.output.iterdir()) - before
                self.assertEqual(len(created), 1)
                self.assertEqual(stat.S_IMODE(created.pop().stat().st_mode), 0o600)
                self.assertEqual(target.read_text(), "original unrelated content")
                if kind == "regular":
                    self.assertEqual(original.read_text(), "original screenshot")
                    self.assertEqual(stat.S_IMODE(original.stat().st_mode), 0o644)
                else:
                    self.assertTrue(original.is_symlink())
                self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o755)

    def test_screenshot_cancellation_and_failure_leave_no_partial_files(self):
        for script, arguments in SCREENSHOTS:
            with self.subTest(script=script, arguments=arguments):
                shutil.rmtree(self.output, ignore_errors=True)
                result = self.run_script(script, arguments, extra={"CAPTURE_FAILURE": "7"})
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(list(self.output.iterdir()), [])
                if arguments in (("area",), ("--instant-area",)):
                    result = self.run_script(script, arguments, extra={"CANCEL": "1"})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(list(self.output.iterdir()), [])

    def test_screenshot_rejects_unsafe_output_directory(self):
        outside = self.root / "outside"
        outside.mkdir()
        self.output.symlink_to(outside)
        result = self.run_script(*SCREENSHOTS[0])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])
        self.output.unlink()
        self.output.mkdir(mode=0o777)
        self.output.chmod(0o777)
        result = self.run_script(*SCREENSHOTS[0])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_interactive_save_copy_and_edit_modes_keep_output_private(self):
        self.tool("sleep", "pass\n")
        self.tool("rofi", """import os, sys
sys.stdin.read()
prompt = sys.argv[sys.argv.index('-p') + 1]
print({'Take screenshot': os.environ['MENU_TIMING'], 'Choose timer': '5s',
       'Type of screenshot': os.environ['MENU_CAPTURE'],
       'How to save': os.environ['MENU_ACTION']}[prompt])
""")
        self.tool("grimblast", """import pathlib, sys
if sys.argv[2] != 'copy':
    pathlib.Path(sys.argv[-1]).write_text('synthetic image')
""")
        for timing in ("Immediate", "Delayed"):
            for action in ("Save", "Copy", "Copy & Save", "Edit"):
                for capture in ("Capture Everything", "Capture Active Display", "Capture Selection"):
                    with self.subTest(timing=timing, action=action, capture=capture):
                        shutil.rmtree(self.output, ignore_errors=True)
                        result = self.run_script(
                            "dotfiles/.config/hypr/scripts/screenshot.sh",
                            extra={"MENU_TIMING": timing, "MENU_ACTION": action,
                                   "MENU_CAPTURE": capture},
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        if action == "Copy":
                            self.assertEqual(list(self.output.iterdir()), [])
                        else:
                            output = self.output / "shot.png"
                            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_empty_capture_is_not_reported_as_success(self):
        self.tool("grim", "pass\n")
        for script, arguments in SCREENSHOTS:
            with self.subTest(script=script, arguments=arguments):
                result = self.run_script(script, arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(self.output.iterdir()), [])

    def archive_fixture(self, operation):
        if operation == "link":
            # Stow expects its own relative links, not our desktop fixture's
            # absolute library link. The archive test does not need the library.
            (self.config / "myhypr/library.sh").unlink(missing_ok=True)
            source = self.config / "kitty/kitty.conf"
            script = "scripts/link-dotfiles.sh"
            arguments = ("--backup-conflicts", "--yes")
            leaf = "backups"
        elif operation == "namespace":
            source = self.config / "ml4w/private.conf"
            script = "scripts/migrate-namespace.sh"
            arguments = ("--yes",)
            leaf = "migrations"
        else:
            source = self.config / "hypr/conf/keybinding.conf"
            script = "scripts/migrate-local.sh"
            arguments = ("--yes",)
            leaf = "migrations"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("synthetic protected config\n")
        source.chmod(0o644)
        archive_parent = self.home / ".local/state/myhyprlandrice" / leaf
        return source, script, arguments, archive_parent

    @unittest.skipUnless(shutil.which("stow"), "stow is unavailable")
    def test_direct_archives_protect_private_source_and_preserve_file_mode(self):
        for operation in ("link", "namespace", "local"):
            with self.subTest(operation=operation):
                source, script, arguments, parent = self.archive_fixture(operation)
                parent.mkdir(parents=True, exist_ok=True)
                for ancestor in (parent, *parent.parents):
                    ancestor.chmod(0o755)
                    if ancestor == self.home:
                        break
                result = self.run_script(script, arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                archived = [path for path in parent.rglob(source.name) if not path.is_symlink()]
                self.assertEqual(len(archived), 1)
                self.assertEqual(archived[0].read_text(), "synthetic protected config\n")
                self.assertEqual(stat.S_IMODE(archived[0].stat().st_mode), 0o644)
                self.assertEqual(stat.S_IMODE(parent.stat().st_mode), 0o700)
                container = parent / archived[0].relative_to(parent).parts[0]
                self.assertEqual(stat.S_IMODE(container.stat().st_mode), 0o700)
                # Isolate the next operation from Stow's linked fixtures.
                self.tearDown_fixture()

    def tearDown_fixture(self):
        shutil.rmtree(self.home)
        self.home.mkdir(mode=0o755)
        self.home.chmod(0o755)
        self.config.mkdir(mode=0o700)

    def test_archive_symlinks_are_rejected_before_source_moves(self):
        self.tool("stow", "pass\n")
        for operation in ("link", "namespace", "local"):
            for component in ("myhyprlandrice", "leaf"):
                with self.subTest(operation=operation, component=component):
                    source, script, arguments, parent = self.archive_fixture(operation)
                    linked = parent if component == "leaf" else parent.parent
                    linked.parent.mkdir(parents=True, exist_ok=True)
                    outside = self.root / "outside"
                    outside.mkdir(exist_ok=True)
                    linked.symlink_to(outside)
                    result = self.run_script(script, arguments)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(source.exists())
                    self.assertEqual(list(outside.iterdir()), [])
                    self.tearDown_fixture()

    def test_archives_have_unique_directories_and_dry_runs_do_not_create_them(self):
        source, script, arguments, parent = self.archive_fixture("namespace")
        self.tool("date", "print('20261004T000000Z')\n")
        original = source.read_text()
        result = self.run_script(script, (*arguments, "--dry-run"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(parent.exists())
        for _ in range(2):
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(original)
            result = self.run_script(script, arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(parent.iterdir())), 2)

    def test_archive_writable_ancestors_are_rejected_before_source_moves(self):
        source, script, arguments, parent = self.archive_fixture("namespace")
        ancestor = parent.parent
        ancestor.mkdir(parents=True)
        ancestor.chmod(0o777)
        result = self.run_script(script, arguments)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(source.exists())
        self.assertFalse(parent.exists())


if __name__ == "__main__":
    unittest.main()
