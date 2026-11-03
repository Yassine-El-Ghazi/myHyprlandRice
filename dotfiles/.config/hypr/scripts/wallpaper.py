#!/usr/bin/env python3
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import traceback


class WallpaperError(Exception):
    pass


def failure_reason(error):
    if isinstance(error, subprocess.TimeoutExpired):
        return "timed out"
    if isinstance(error, subprocess.CalledProcessError):
        return f"exit status {error.returncode}"
    if isinstance(error, OSError):
        return os.strerror(error.errno) if isinstance(error.errno, int) else "I/O error"
    if isinstance(error, UnicodeError):
        return "invalid text encoding"
    return "invalid input or state"


class WallpaperParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, "Wallpaper: invalid arguments; use --help for supported options.\n")


class Wallpaper:
    def __init__(self, verbose=False):
        self.verbose = verbose
        self.child_output = sys.stderr if verbose else subprocess.DEVNULL
        self.home = Path.home()
        self.config = self.home / ".config"
        self.scripts = Path(__file__).resolve().parent
        self.cache = self.home / ".cache/myhypr"
        self.state_file = self.cache / "current_wallpaper"
        self.generated = self.cache / "wallpaper-generated"
        self.settings = self.config / "myhypr/settings"
        self.default = self.config / "myhypr/wallpapers/default.jpg"
        self.effect_helper = self.config / "hypr/scripts/wallpaper-effect.sh"

    @contextlib.contextmanager
    def operation(self, action):
        try:
            yield
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            raise WallpaperError(f"{action} failed ({failure_reason(error)})") from error

    @contextlib.contextmanager
    def locked(self):
        self.cache.mkdir(parents=True, exist_ok=True, mode=0o700)
        metadata = self.cache.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
            raise WallpaperError("Wallpaper cache must be a private, user-owned directory")
        descriptor = os.open(self.cache / "wallpaper-pipeline.lock",
                             os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "rb") as lock:
            metadata = os.fstat(lock.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
                raise WallpaperError("Invalid wallpaper lock")
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.lock_descriptor = lock.fileno()
            yield

    def read_state(self):
        try:
            data = json.loads(self.state_file.read_bytes())
        except FileNotFoundError:
            return None
        except (ValueError, UnicodeError, RecursionError) as error:
            raise WallpaperError("Malformed wallpaper state; make an explicit selection to replace it") from error
        if (not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 1
                or set(data) != {"version", "original", "applied", "effect"}
                or not isinstance(data["effect"], str)):
            raise WallpaperError("Invalid wallpaper state schema")
        for field in ("original", "applied"):
            if not isinstance(data[field], str) or not data[field].startswith("/") or "\0" in data[field]:
                raise WallpaperError("Invalid wallpaper state path")
            os.fsencode(data[field])
        return data

    def prepare_state(self, data):
        descriptor, name = tempfile.mkstemp(prefix=".wallpaper-state-", dir=self.cache)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(json.dumps(data, ensure_ascii=True, sort_keys=True).encode("ascii") + b"\n")
                stream.flush()
                os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
        return temporary

    def backend(self):
        retired = {self.scripts / "wallpaper-backend", self.config / "hypr/scripts/wallpaper-backend"}
        retired = {path.resolve() for path in retired}
        script_directories = {self.scripts.resolve(), (self.config / "hypr/scripts").resolve()}
        for directory in os.get_exec_path():
            if not os.path.isabs(directory):
                continue
            candidate = Path(directory) / "awww"
            if candidate.parent.resolve() in retired:
                continue
            try:
                resolved = candidate.resolve(strict=True)
            except (OSError, RuntimeError):
                continue
            if any(resolved.is_relative_to(path) for path in retired | script_directories):
                continue
            if resolved.is_file() and os.access(resolved, os.X_OK):
                return str(resolved)
        raise WallpaperError("No real awww executable found outside the retired adapter directory")

    def run_locked(self, arguments, action):
        with self.operation(action):
            subprocess.run(["timeout", "--kill-after=5s", "30s", *arguments], check=True,
                           pass_fds=(self.lock_descriptor,), stdin=subprocess.DEVNULL,
                           stdout=self.child_output, stderr=self.child_output)

    def effects(self):
        with self.operation("Effect listing"):
            result = subprocess.run([str(self.effect_helper), "--list"],
                                    check=True, stdout=subprocess.PIPE, stderr=self.child_output,
                                    text=True, timeout=5)
        return [*result.stdout.splitlines(), "off"]

    def seed_effect(self):
        try:
            return (self.settings / "wallpaper-effect.sh").read_text().rstrip("\n") or "off"
        except FileNotFoundError:
            return "off"

    def snapshot(self, original, effect):
        if not original.is_absolute() or not original.is_file():
            raise WallpaperError("Wallpaper source is missing or is not a regular file")
        self.generated.mkdir(exist_ok=True, mode=0o700)
        metadata = self.generated.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
            raise WallpaperError("Wallpaper assets must be a user-owned directory without shared write access")
        self.generated.chmod(0o700)
        with tempfile.TemporaryDirectory(prefix=".prepare-", dir=self.generated) as directory:
            source = Path(directory) / "source"
            digest = hashlib.sha256(os.fsencode(original))
            with original.open("rb") as incoming, source.open("wb") as outgoing:
                while block := incoming.read(1024 * 1024):
                    digest.update(block)
                    outgoing.write(block)
            digest.update(effect.encode("ascii"))
            with source.open("rb") as stream:
                header = stream.read(32)
            extension = original.suffix.lower()
            for signature, suffix in ((b"\x89PNG", ".png"), (b"\xff\xd8\xff", ".jpg"),
                                      (b"GIF8", ".gif"), (b"BM", ".bmp"),
                                      (b"II*\0", ".tiff"), (b"MM\0*", ".tiff")):
                if header.startswith(signature):
                    extension = suffix
                    break
            if header.startswith(b"RIFF") and header[8:12] == b"WEBP":
                extension = ".webp"
            if extension not in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tiff", ".avif"}:
                extension = ".png"
            destination = self.generated / (digest.hexdigest() + (extension if effect == "off" else ".png"))
            prepared = source
            if effect != "off":
                prepared = Path(directory) / "effect.png"
                self.run_locked([str(self.effect_helper), effect, str(source), str(prepared)],
                                "Effect generation")
            with prepared.open("rb") as stream:
                os.fsync(stream.fileno())
            prepared.chmod(0o600)
            os.replace(prepared, destination)
            descriptor = os.open(self.generated, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        return destination

    def ensure_backend(self, backend):
        def ready():
            try:
                return subprocess.run([backend, "query"], stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, timeout=2).returncode == 0
            except subprocess.TimeoutExpired:
                return False

        if ready():
            return
        subprocess.Popen(["awww-daemon"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
        for _ in range(30):
            if ready():
                return
            time.sleep(0.1)
        raise WallpaperError("Awww daemon did not become ready")

    def mode(self):
        try:
            lines = (self.config / "gtk-3.0/settings.ini").read_text().splitlines()
        except FileNotFoundError:
            return "light"
        for line in lines:
            if line.split("=", 1)[0].strip() == "gtk-application-prefer-dark-theme":
                return "dark" if line.partition("=")[2].strip() in ("1", "true") else "light"
        return "light"

    def refresh(self, data):
        applied = data["applied"]
        if not Path(applied).is_file():
            raise WallpaperError("Applied wallpaper asset is missing; restore it before refreshing")
        failures = []

        def update(action, arguments, retain_lock=True):
            try:
                if retain_lock:
                    self.run_locked(arguments, action)
                else:
                    with self.operation(action):
                        subprocess.run(arguments, check=True, timeout=30,
                                       stdout=self.child_output, stderr=self.child_output)
            except WallpaperError as error:
                failures.append(str(error))

        if shutil.which("matugen"):
            update("Matugen refresh", ["matugen", "image", applied, "-m", self.mode(),
                                       "--source-color-index", "0"])
        else:
            failures.append("matugen is not installed")
        blurred = self.cache / "blurred_wallpaper.png"
        square = self.cache / "square_wallpaper.png"
        blur = "50x30"
        try:
            blur = (self.settings / "blur.sh").read_text().rstrip("\n")
        except FileNotFoundError:
            pass
        parts = blur.split("x")
        if len(parts) != 2 or not all(part.isascii() and part.isdecimal() for part in parts):
            failures.append("Invalid blur setting")
        else:
            blur_arguments = [] if blur == "0x0" else ["-blur", blur]
            update("Blurred asset refresh", ["magick", applied, "-resize", "75%", *blur_arguments, str(blurred)])
            (self.cache / "current_wallpaper.rasi").write_text(
                '* { current-image: url(' + json.dumps(str(blurred)) + ', height); }\n')
        update("Square asset refresh", ["magick", applied, "-gravity", "Center", "-extent", "1:1", str(square)])
        update("Waybar refresh", [str(self.config / "waybar/launch.sh")], retain_lock=False)
        try:
            with contextlib.ExitStack() as stack:
                output = subprocess.DEVNULL
                if self.verbose:
                    output = stack.enter_context((self.cache / "wallpaper-panels.log").open("ab"))
                    os.fchmod(output.fileno(), 0o600)
                dock = subprocess.Popen([str(self.config / "nwg-dock-hyprland/launch.sh")],
                                        stdout=output, stderr=output, start_new_session=True, close_fds=True)
            try:
                status = dock.wait(timeout=0.1)
                if status:
                    failures.append(f"Dock refresh failed (exit status {status})")
            except subprocess.TimeoutExpired:
                pass
        except OSError as error:
            failures.append(f"Dock refresh failed ({failure_reason(error)})")
        if shutil.which("pywalfox"):
            update("Firefox color refresh", ["pywalfox", "update"])
        update("Notification refresh", ["swaync-client", "-rs"])
        if failures:
            raise WallpaperError("Wallpaper state is committed; post-apply updates failed: " + "; ".join(failures)
                                 + ". Retry with wallpaper.sh --refresh")

    def transition(self, original=None, effect=None, refresh=False, restore=False):
        with self.operation("Wallpaper state access"), self.locked():
            try:
                previous = self.read_state()
            except (WallpaperError, ValueError):
                if original is None:
                    raise
                print("Ignoring invalid wallpaper state for explicit selection.", file=sys.stderr)
                previous = None
            if refresh:
                if previous:
                    with self.operation("Wallpaper state is committed; post-apply updates"):
                        self.refresh(previous)
                return
            if original is None:
                original = previous["original"] if previous else str(self.default)
            identity = os.fspath(original)
            if not os.path.isabs(identity):
                identity = os.path.join(os.getcwd(), identity)
            original = Path(identity)
            if effect is None:
                effect = previous["effect"] if previous else self.seed_effect()
            if effect not in self.effects():
                raise WallpaperError("Unsupported wallpaper effect; choose one from the effect picker")
            if restore and previous and effect == previous["effect"] and Path(previous["applied"]).is_file():
                applied = Path(previous["applied"])
            else:
                with self.operation("Wallpaper preparation"):
                    applied = self.snapshot(original, effect)
            data = {"version": 1, "original": identity, "applied": str(applied), "effect": effect}
            backend = self.backend()
            with self.operation("State preparation"):
                temporary = self.prepare_state(data)
            try:
                with self.operation("Backend startup"):
                    self.ensure_backend(backend)
                self.run_locked([backend, "img", str(applied)], "Backend application")
                try:
                    os.replace(temporary, self.state_file)
                except OSError as error:
                    if previous and Path(previous["applied"]).is_file():
                        self.run_locked([backend, "img", previous["applied"]], "Wallpaper rollback")
                    raise WallpaperError(f"State publication failed ({failure_reason(error)}); retry restore") from error
                with self.operation("Wallpaper state is committed; directory sync"):
                    descriptor = os.open(self.cache, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
            finally:
                temporary.unlink(missing_ok=True)
            with self.operation("Wallpaper state is committed; post-apply updates"):
                self.refresh(data)
            print("Wallpaper applied successfully.")

    def images(self):
        folder = self.config / "myhypr/wallpapers"
        try:
            value = (self.settings / "wallpaper-folder").read_text(errors="surrogateescape").removesuffix("\n")
            if value.startswith("$HOME/"):
                value = str(self.home) + value[5:]
            folder = Path(os.path.expanduser(value))
            if not folder.is_absolute():
                folder = self.home / folder
        except FileNotFoundError:
            pass
        extensions = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".avif", ".tiff"}
        images = []
        for directory, subdirectories, names in os.walk(folder):
            if len(Path(directory).relative_to(folder).parts) >= 5:
                subdirectories.clear()
            for name in names:
                path = Path(directory) / name
                if path.is_file() and Path(name.rstrip()).suffix.lower() in extensions:
                    images.append(path)
        if not images:
            raise WallpaperError("No supported wallpaper images found in the configured folder")
        return sorted(images)

    def pick(self, choices, prompt):
        labels = [json.dumps(str(choice), ensure_ascii=False) for choice in choices]
        with self.operation("Wallpaper picker"):
            result = subprocess.run(["rofi", "-dmenu", "-i", "-format", "i", "-p", prompt],
                                    input=("\n".join(labels) + "\n").encode("utf-8", errors="backslashreplace"),
                                    capture_output=True)
        if result.returncode:
            return None
        try:
            index = int(result.stdout)
            if index < 0:
                raise ValueError
            return choices[index]
        except (ValueError, IndexError) as error:
            raise WallpaperError("Wallpaper picker returned an invalid selection") from error


def main():
    parser = WallpaperParser(prog="wallpaper.sh", description="Apply one repository wallpaper across all outputs")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--wallpaper")
    actions.add_argument("--random", action="store_true")
    actions.add_argument("--restore", action="store_true")
    actions.add_argument("--refresh", action="store_true")
    actions.add_argument("--pick", action="store_true")
    actions.add_argument("--pick-effect", action="store_true")
    actions.add_argument("--list", dest="list_images", action="store_true")
    parser.add_argument("--effect")
    parser.add_argument("--verbose", action="store_true",
                        help="show raw command output and tracebacks; may disclose private paths")
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    if args.path and any((args.wallpaper, args.random, args.restore, args.refresh, args.pick, args.pick_effect, args.list_images)):
        parser.error("a direct path cannot be combined with another selection action")
    if args.refresh and args.effect:
        parser.error("--refresh cannot change the effect")
    wallpaper = Wallpaper(verbose=args.verbose)
    try:
        if args.list_images:
            for image in wallpaper.images():
                sys.stdout.buffer.write(os.fsencode(image) + b"\0")
            return 0
        original = args.wallpaper or args.path
        effect = args.effect
        if args.pick_effect:
            effect = wallpaper.pick(wallpaper.effects(), "Wallpaper effect")
            if effect is None:
                return 0
        elif args.pick:
            original = wallpaper.pick(wallpaper.images(), "Wallpaper")
            if original is None:
                return 0
        elif args.random:
            original = random.SystemRandom().choice(wallpaper.images())
        wallpaper.transition(original=original, effect=effect, refresh=args.refresh, restore=args.restore)
    except KeyboardInterrupt:
        print("Wallpaper: operation interrupted; use --restore to reconcile wallpaper state.", file=sys.stderr)
        if args.verbose:
            traceback.print_exc()
        return 130
    except (WallpaperError, OSError, ValueError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, WallpaperError) else "Operation failed (" + failure_reason(error) + ")"
        print("Wallpaper: " + message + ". Retry with --verbose for diagnostic details.", file=sys.stderr)
        if args.verbose:
            traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
