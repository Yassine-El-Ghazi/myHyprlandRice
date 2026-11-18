#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import zlib


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'dotfiles/.config/hypr/scripts/wallpaper_visual.py'
SPEC = importlib.util.spec_from_file_location('wallpaper_visual', SCRIPT)
visual = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(visual)


def image(width=2, height=2):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    pixels = (b'\0' + b'\xff\0\0' * width) * height
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


def large_image():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    width, height = 10001, 8000
    compressor = zlib.compressobj(1)
    row = b'\0' * (1 + width * 3)
    compressed = b''.join(compressor.compress(row) for _index in range(height)) + compressor.flush()
    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', compressed) + chunk(b'IEND', b'')


class VisualPickerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='visual-picker-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {**os.environ, 'HOME': str(self.root), 'XDG_CONFIG_HOME': str(self.root / 'config'),
                    'XDG_CACHE_HOME': str(self.root / 'cache'), 'XDG_RUNTIME_DIR': str(self.root),
                    'DISPLAY': '', 'WAYLAND_DISPLAY': '', 'DBUS_SESSION_BUS_ADDRESS': ''}

    def worker(self, path):
        return subprocess.run([sys.executable, str(SCRIPT), '--thumbnail'], input=os.fsencode(path),
                              env=self.env, capture_output=True, timeout=10)

    def test_byte_paths_and_preview_frames(self):
        names = [b'white space.png', b"quotes-'\".png", b'$(no);.png', '雪.png'.encode(),
                 b'back\\slash.png', b'line\nbreak.png', b'trailing.png\n', b'invalid-\xff.png']
        for name in names:
            with self.subTest(name=repr(name)):
                path = os.fsencode(self.root) + b'/' + name
                with open(path, 'wb') as stream:
                    stream.write(image())
                result = self.worker(path)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(visual.decode_frame(result.stdout)[:2], (2, 2))
                self.assertEqual(result.stderr, b'')

    def test_display_names_do_not_collide_with_escapes(self):
        self.assertNotEqual(visual.display_name(Path('line\nbreak.png')),
                            visual.display_name(Path('line\\nbreak.png')))
        self.assertNotEqual(visual.display_name(Path(os.fsdecode(b'invalid-\xff.png'))),
                            visual.display_name(Path('invalid-\\xff.png')))
        self.assertIn('雪', visual.display_name(Path('雪.png')))

    def test_corrupt_unsupported_and_large_images_are_rejected(self):
        for contents in (b'not an image', b'\x89PNG\r\n\x1a\ncorrupt'):
            path = self.root / 'bad.png'
            path.write_bytes(contents)
            result = self.worker(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stderr, b'')
        path = self.root / 'large.png'
        with path.open('wb') as stream:
            stream.truncate(visual.MAX_INPUT + 1)
        self.assertNotEqual(self.worker(path).returncode, 0)
        header = struct.pack('>IIBBBBB', 40000, 40000, 8, 2, 0, 0, 0)
        chunk = b'IHDR' + header
        path.write_bytes(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', len(header)) + chunk +
                         struct.pack('>I', zlib.crc32(chunk)))
        self.assertNotEqual(self.worker(path).returncode, 0)
        path.write_bytes(large_image())
        self.assertNotEqual(self.worker(path).returncode, 0)

    def test_bounded_frame_validation(self):
        valid = visual.HEADER.pack(b'RGBA', 1, 1, 4) + b'1234'
        self.assertEqual(visual.decode_frame(valid), (1, 1, b'1234'))
        for frame in (b'', valid[:-1], valid + b'x', visual.HEADER.pack(b'RGBA', 257, 1, 1028),
                      visual.HEADER.pack(b'JPEG', 1, 1, 4) + b'1234'):
            self.assertIsNone(visual.decode_frame(frame))

    def test_valid_large_preview_is_scaled(self):
        path = self.root / 'synthetic-large.png'
        path.write_bytes(image(1600, 900))
        result = self.worker(path)
        self.assertEqual(result.returncode, 0)
        width, height, _pixels = visual.decode_frame(result.stdout)
        self.assertLessEqual(width, visual.MAX_WIDTH)
        self.assertLessEqual(height, visual.MAX_HEIGHT)

    def test_pool_bounds_and_stalled_worker_cleanup(self):
        self.assertEqual(visual.MAX_WORKERS, 2)
        self.assertEqual(visual.MAX_PENDING, 4)
        results = []
        pool = visual.PreviewPool(lambda index, future: results.append((index, future)))
        original = subprocess.Popen
        def sleeper(*_args, **kwargs):
            return original([sys.executable, '-c', 'import time; time.sleep(30)'], **kwargs)
        with mock.patch.object(visual.subprocess, 'Popen', side_effect=sleeper), mock.patch.object(visual, 'TIMEOUT', .2):
            start = time.monotonic()
            self.assertIsNone(pool.run(b'/synthetic'))
            self.assertLess(time.monotonic() - start, 3)
            start = time.monotonic()
            self.assertIsNone(pool.run(b'/' + b'x' * 65535))
            self.assertLess(time.monotonic() - start, 3)
            for index in range(visual.MAX_PENDING):
                self.assertTrue(pool.request(index, Path('/synthetic')))
            self.assertFalse(pool.request(visual.MAX_PENDING, Path('/synthetic')))
            pool.close()
        self.assertFalse(pool.processes)

    def test_worker_output_is_bounded_before_buffering(self):
        pool = visual.PreviewPool(lambda _index, _future: None)
        original = subprocess.Popen
        def noisy(*_args, **kwargs):
            code = 'import sys; sys.stdin.buffer.read(); sys.stdout.buffer.write(b"x" * 500000)'
            return original([sys.executable, '-c', code], **kwargs)
        with mock.patch.object(visual.subprocess, 'Popen', side_effect=noisy):
            self.assertIsNone(pool.run(b'/synthetic'))
        pool.close()
        self.assertFalse(pool.processes)

    def test_missing_display_fails_without_path_leak(self):
        env = self.env
        result = subprocess.run([sys.executable, '-c', '''
import sys
sys.path.insert(0, sys.argv[1])
from wallpaper_visual import pick_wallpaper, PickerError
try:
    pick_wallpaper(None)
except PickerError as error:
    print(error, file=sys.stderr)
    sys.exit(1)
''', str(SCRIPT.parent)], env=env, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'/home/example/Pictures/secret-wallpaper.png', result.stdout + result.stderr)
        self.assertNotIn(os.fsencode(self.root), result.stdout + result.stderr)
        private_path = b'/home/example/Pictures/secret-wallpaper.png'
        failed_preview = self.worker(private_path)
        self.assertNotEqual(failed_preview.returncode, 0)
        self.assertNotIn(private_path, failed_preview.stdout + failed_preview.stderr)

    def test_missing_bindings_are_a_distinct_error(self):
        with mock.patch.dict(sys.modules, {'gi': None}):
            with self.assertRaises(visual.PickerError):
                visual.pick_wallpaper(None)

    def test_native_diagnostics_are_private_unless_verbose(self):
        program = '''
import os, sys
from types import SimpleNamespace
sys.path.insert(0, sys.argv[1])
import wallpaper_visual
wallpaper_visual.run_picker = lambda _: os.write(2, b"/home/example/Pictures/secret-wallpaper.png")
wallpaper_visual.pick_wallpaper(SimpleNamespace(verbose=False))
'''
        result = subprocess.run([sys.executable, '-c', program, str(SCRIPT.parent)],
                                env=self.env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b'')

    def test_picker_discovery_matches_existing_discovery(self):
        spec = importlib.util.spec_from_file_location('engine', SCRIPT.with_name('wallpaper.py'))
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)
        with mock.patch.object(Path, 'home', return_value=self.root):
            instance = engine.Wallpaper()
            folder = instance.config / 'myhypr/wallpapers'
            folder.mkdir(parents=True)
            for name in ('visible.PNG', '.hidden.jpg', 'trailing.png\n', 'not-image.txt'):
                (folder / name).write_bytes(b'synthetic')
            nested = folder
            for depth in range(6):
                nested = nested / str(depth)
                nested.mkdir()
                (nested / 'nested.jpg').write_bytes(b'synthetic')
            (folder / 'link.png').symlink_to(folder / 'visible.PNG')
            normal = instance.images()
            picker = instance.images(allow_empty=True, onerror=lambda _error: None)
            self.assertEqual(normal, picker)
            self.assertIn(folder / '.hidden.jpg', picker)
            self.assertIn(folder / 'trailing.png\n', picker)
            self.assertIn(folder / 'link.png', picker)
            self.assertNotIn(folder / 'not-image.txt', picker)
            self.assertNotIn(nested / 'nested.jpg', picker)

    def test_browser_navigation_identity_and_boundaries(self):
        root = self.root / 'wallpapers'
        root.mkdir()
        folder_name = 'odd \' " $(name); \\ 雪\n'
        folder = root / folder_name
        folder.mkdir()
        nested = folder / 'nested'
        nested.mkdir()
        unusual = os.fsdecode(b'invalid-\xff.png\n')
        (folder / unusual).write_bytes(image())
        (folder / 'ignored.txt').write_bytes(b'unsupported')
        (root / 'external').symlink_to(self.root, target_is_directory=True)
        (root / 'link.png').symlink_to(folder / unusual)
        browser = visual.Browser(root)
        top = browser.scan(())
        self.assertEqual([(item.path.name, item.directory) for item in top], [(folder_name, True)])
        browser.move((folder_name,))
        contents = browser.scan(browser.current)
        self.assertEqual([(item.path.name, item.directory) for item in contents],
                         [('nested', True), (unusual, False)])
        self.assertEqual(os.fsencode(contents[1].path), os.fsencode(folder / unusual))
        browser.move((folder_name, 'nested'))
        self.assertEqual(browser.scan(browser.current), ())
        browser.back()
        self.assertEqual(browser.current, (folder_name,))
        browser.move(browser.current[:-1])
        self.assertEqual(browser.current, ())
        for parts in (('..',), ('/',), ('external',)):
            with self.subTest(parts=parts), self.assertRaises((visual.PickerError, OSError)):
                browser.move(parts)
                browser.scan(parts)

    def test_browser_rejects_symlink_replacement(self):
        root = self.root / 'wallpapers'
        root.mkdir()
        outside = self.root / 'outside'
        outside.mkdir()
        (root / 'folder').symlink_to(outside, target_is_directory=True)
        browser = visual.Browser(root)
        with self.assertRaises(OSError):
            browser.scan(('folder',))
        with self.assertRaises(visual.PickerError):
            browser.scan(('..',))

    @unittest.skipUnless(shutil.which('xvfb-run'), 'xvfb-run unavailable')
    def test_visual_only_navigation_and_selection(self):
        runtime = self.root / 'runtime'
        runtime.mkdir(mode=0o700)
        root = self.root / 'wallpapers'
        folder = root / 'Nature'
        folder.mkdir(parents=True)
        (folder / 'image.png').write_bytes(image())
        env = {**self.env, 'XDG_RUNTIME_DIR': str(runtime), 'GSK_RENDERER': 'cairo',
               'DBUS_SESSION_BUS_ADDRESS': '', 'WAYLAND_DISPLAY': ''}
        program = '''
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import GLib, Gtk
import wallpaper_visual
provider = Gtk.CssProvider()
errors = []
provider.connect('parsing-error', lambda _provider, _section, error: errors.append(str(error)))
provider.load_from_data(wallpaper_visual.BROWSER_CSS)
assert not errors, errors
class Fake:
    def wallpaper_folder(self): return Path(sys.argv[2])
def walk(widget):
    yield widget
    child = widget.get_first_child()
    while child:
        yield from walk(child)
        child = child.get_next_sibling()
step = 0
def action():
    global step
    windows = Gtk.Window.get_toplevels()
    if not windows: return True
    window = windows[0]
    widgets = list(walk(window))
    grid = next(widget for widget in widgets if isinstance(widget, Gtk.GridView))
    buttons = {widget.get_label(): widget for widget in widgets if isinstance(widget, Gtk.Button)}
    if step == 0:
        if grid.get_model().get_n_items() != 1: return True
        assert {'Folder', 'Clear', 'Refresh', 'Random', 'Exit'} <= set(buttons)
        buttons['Folder'].set_active(False)
        buttons['Folder'].set_active(True)
        assert grid.get_model().get_item(0).directory
        grid.emit('activate', 0)
    elif step == 1:
        if 'Nature' not in buttons or grid.get_model().get_n_items() != 1: return True
        assert not grid.get_model().get_item(0).directory
        grid.get_model().set_selected(0)
        buttons['Random'].emit('clicked')
        assert grid.get_model().get_selected_item() is not None
        assert not buttons['Apply wallpaper'].get_sensitive()
        buttons['Apply wallpaper'].emit('clicked')
        assert Gtk.Window.get_toplevels().get_n_items() > 0
    elif step == 2:
        search = next(widget for widget in widgets if isinstance(widget, Gtk.SearchEntry))
        search.set_text('missing')
    elif step == 3:
        if grid.get_model().get_n_items(): return True
        buttons['Refresh'].emit('clicked')
    elif step == 4:
        search = next(widget for widget in widgets if isinstance(widget, Gtk.SearchEntry))
        assert search.get_text() == 'missing'
        if not any(isinstance(widget, Gtk.Label) and widget.get_label() == 'No wallpapers match your search.' for widget in widgets): return True
        buttons['Up'].emit('clicked')
    elif step == 5:
        if grid.get_model().get_n_items() != 1 or 'Nature' in buttons: return True
        buttons['Back'].emit('clicked')
    elif step == 6:
        if 'Nature' not in buttons or grid.get_model().get_n_items() != 1: return True
        buttons['Wallpapers'].emit('clicked')
    elif step == 7:
        if 'Nature' in buttons or grid.get_model().get_n_items() != 1: return True
        buttons['Cancel'].emit('clicked')
        return False
    step += 1
    return True
GLib.timeout_add(100, action)
assert wallpaper_visual.pick_wallpaper(Fake(), visual_only=True) is None
assert step == 7
'''
        result = subprocess.run(['xvfb-run', '-a', sys.executable, '-c', program, str(SCRIPT.parent), str(root)],
                                env=env, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))

    @unittest.skipUnless(shutil.which('xvfb-run'), 'xvfb-run unavailable')
    def test_search_changes_clear_selection_before_actions(self):
        runtime = self.root / 'runtime'
        runtime.mkdir(mode=0o700)
        root = self.root / 'wallpapers'
        root.mkdir()
        for name in ('a.png', 'b.png'):
            (root / name).write_bytes(image())
        env = {**self.env, 'XDG_RUNTIME_DIR': str(runtime), 'GSK_RENDERER': 'cairo',
               'DBUS_SESSION_BUS_ADDRESS': '', 'WAYLAND_DISPLAY': ''}
        program = '''
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import GLib, Gtk
import wallpaper_visual
class Fake:
    def wallpaper_folder(self): return Path(sys.argv[2])
def walk(widget):
    yield widget
    child = widget.get_first_child()
    while child:
        yield from walk(child)
        child = child.get_next_sibling()
def action():
    windows = Gtk.Window.get_toplevels()
    if not windows: return True
    window = windows[0]
    widgets = list(walk(window))
    grid = next(widget for widget in widgets if isinstance(widget, Gtk.GridView))
    if grid.get_model().get_n_items() != 2: return True
    buttons = {widget.get_label(): widget for widget in widgets if isinstance(widget, Gtk.Button)}
    search = next(widget for widget in widgets if isinstance(widget, Gtk.SearchEntry))
    grid.get_model().set_selected(0)
    assert buttons['Apply wallpaper'].get_sensitive()
    search.set_text('missing')
    assert grid.get_model().get_n_items() == 0
    assert grid.get_model().get_selected_item() is None
    assert not buttons['Apply wallpaper'].get_sensitive()
    buttons['Random'].emit('clicked')
    buttons['Apply wallpaper'].emit('clicked')
    assert window.get_visible()
    search.set_text('b.png')
    assert grid.get_model().get_n_items() == 1
    buttons['Random'].emit('clicked')
    assert grid.get_model().get_selected_item().label == 'b.png'
    buttons['Apply wallpaper'].emit('clicked')
    return False
GLib.timeout_add(100, action)
assert wallpaper_visual.pick_wallpaper(Fake()) == Path(sys.argv[2]) / 'b.png'
'''
        result = subprocess.run(['xvfb-run', '-a', sys.executable, '-c', program, str(SCRIPT.parent), str(root)],
                                env=env, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))

    @unittest.skipUnless(shutil.which('xvfb-run'), 'xvfb-run unavailable')
    def test_stale_folder_and_preview_results_are_ignored(self):
        runtime = self.root / 'runtime'
        runtime.mkdir(mode=0o700)
        root = self.root / 'wallpapers'
        folder = root / 'Nature'
        folder.mkdir(parents=True)
        for name in ('a.png', 'b.png'):
            (folder / name).write_bytes(image())
        env = {**self.env, 'XDG_RUNTIME_DIR': str(runtime), 'GSK_RENDERER': 'cairo',
               'DBUS_SESSION_BUS_ADDRESS': '', 'WAYLAND_DISPLAY': ''}
        program = '''
import sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import GLib, Gtk
import wallpaper_visual
original_scan = wallpaper_visual.Browser.scan
def slow_scan(self, parts):
    if parts: time.sleep(.5)
    return original_scan(self, parts)
wallpaper_visual.Browser.scan = slow_scan
def preview(self, path):
    if path.endswith(b'a.png'): time.sleep(.8)
    else: time.sleep(.05)
    return (1, 1, b'\\xff\\x00\\x00\\xff')
wallpaper_visual.PreviewPool.run = preview
class Fake:
    def wallpaper_folder(self): return Path(sys.argv[2])
def walk(widget):
    yield widget
    child = widget.get_first_child()
    while child:
        yield from walk(child)
        child = child.get_next_sibling()
step = 0
started = 0
texture = None
def action():
    global step, started, texture
    windows = Gtk.Window.get_toplevels()
    if not windows: return True
    widgets = list(walk(windows[0]))
    grid = next(item for item in widgets if isinstance(item, Gtk.GridView))
    buttons = {item.get_label(): item for item in widgets if isinstance(item, Gtk.Button)}
    if step == 0:
        if grid.get_model().get_n_items() != 1: return True
        grid.emit('activate', 0)
        buttons['Up'].emit('clicked')
        started = time.monotonic()
    elif step == 1:
        if time.monotonic() - started < .9: return True
        assert grid.get_model().get_n_items() == 1
        assert grid.get_model().get_item(0).directory
        grid.emit('activate', 0)
    elif step == 2:
        if grid.get_model().get_n_items() != 2: return True
        grid.get_model().set_selected(0)
        grid.get_model().set_selected(1)
        started = time.monotonic()
    elif step == 3:
        picture = next(item for item in widgets if isinstance(item, Gtk.Picture) and item.get_size_request().width == 200)
        if not picture.get_paintable(): return True
        texture = picture.get_paintable()
    elif step == 4:
        if time.monotonic() - started < 1.4: return True
        picture = next(item for item in widgets if isinstance(item, Gtk.Picture) and item.get_size_request().width == 200)
        assert picture.get_paintable() == texture
        buttons['Cancel'].emit('clicked')
        return False
    step += 1
    return True
GLib.timeout_add(100, action)
assert wallpaper_visual.pick_wallpaper(Fake(), visual_only=True) is None
assert step == 4
'''
        result = subprocess.run(['xvfb-run', '-a', sys.executable, '-c', program, str(SCRIPT.parent), str(root)],
                                env=env, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))

    @unittest.skipUnless(shutil.which('xvfb-run'), 'xvfb-run unavailable')
    def test_real_gui_outcomes_on_disposable_display(self):
        runtime = self.root / 'runtime'
        runtime.mkdir(mode=0o700)
        with open(os.fsencode(self.root) + b'/strange-\xff\n.png', 'wb') as stream:
            stream.write(image())
        env = {**self.env, 'XDG_RUNTIME_DIR': str(runtime),
               'GSK_RENDERER': 'cairo', 'DBUS_SESSION_BUS_ADDRESS': '', 'WAYLAND_DISPLAY': ''}
        program = '''
import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Gdk', '4.0')
from gi.repository import Gdk, GLib, Gtk
import wallpaper_visual
mode = sys.argv[2]
path = Path(os.fsdecode(os.fsencode(sys.argv[3]) + b'/strange-\\xff\\n.png'))
class Fake:
    def wallpaper_folder(self): return Path(sys.argv[3])
def scan(self, parts):
    if mode == 'large': return tuple(wallpaper_visual.Candidate(Path('/synthetic') / f'image-{index}.png', False) for index in range(5000))
    return () if mode == 'empty' else (wallpaper_visual.Candidate(Path('/synthetic/other.png'), False), wallpaper_visual.Candidate(path, False))
wallpaper_visual.Browser.scan = scan
def walk(widget):
    yield widget
    child = widget.get_first_child()
    while child:
        yield from walk(child)
        child = child.get_next_sibling()
attempts = 0
def action():
    global attempts
    attempts += 1
    windows = Gtk.Window.get_toplevels()
    if not windows: return True
    window = windows[0]
    if mode == 'large':
        grid = next(item for item in walk(window) if isinstance(item, Gtk.GridView))
        if grid.get_model().get_n_items() != 5000: return True
        window.close()
        return False
    if mode in ('close', 'empty'):
        if mode == 'empty' and not any(isinstance(item, Gtk.Label) and item.get_label() == 'This folder is empty.' for item in walk(window)):
            return True
        window.close()
        return False
    widgets = list(walk(window))
    grid = next(item for item in widgets if isinstance(item, Gtk.GridView))
    if grid.get_model().get_n_items() != 2 and not (mode in ('search', 'filter') and attempts > 2): return True
    if mode == 'cancel':
        next(item for item in widgets if isinstance(item, Gtk.Button) and item.get_label() == 'Cancel').emit('clicked')
        return False
    if mode == 'exit':
        next(item for item in widgets if isinstance(item, Gtk.Button) and item.get_label() == 'Exit').emit('clicked')
        return False
    if mode == 'random':
        next(item for item in widgets if isinstance(item, Gtk.Button) and item.get_label() == 'Random').emit('clicked')
        assert grid.get_model().get_selected_item() is not None
        assert Gtk.Window.get_toplevels().get_n_items() > 0
        window.close()
        return False
    if mode == 'escape':
        controllers = window.observe_controllers()
        for index in range(controllers.get_n_items()):
            controller = controllers.get_item(index)
            if isinstance(controller, Gtk.EventControllerKey):
                controller.emit('key-pressed', Gdk.KEY_Escape, 0, Gdk.ModifierType(0))
                return False
        raise AssertionError('key controller missing')
    if mode == 'preview':
        if not any(isinstance(item, Gtk.Picture) and item.get_paintable() for item in widgets): return True
        window.close()
        return False
    if mode == 'search':
        search = next(item for item in widgets if isinstance(item, Gtk.SearchEntry))
        if not search.get_text():
            search.set_text('missing-match')
            return True
        if grid.get_model().get_n_items(): return True
        assert any(isinstance(item, Gtk.Label) and item.get_label() == 'No wallpapers match your search.' for item in widgets)
        window.close()
        return False
    if mode == 'filter':
        search = next(item for item in widgets if isinstance(item, Gtk.SearchEntry))
        if not search.get_text():
            search.set_text('strange')
            return True
        if grid.get_model().get_n_items() != 1: return True
        grid.get_model().set_selected(0)
    else:
        grid.get_model().set_selected(1)
    if mode == 'invalid':
        grid.get_model().get_selected_item().index = -1
    next(item for item in widgets if isinstance(item, Gtk.Button) and item.get_label() == 'Apply wallpaper').emit('clicked')
    return False
GLib.timeout_add(100, action)
try:
    result = wallpaper_visual.pick_wallpaper(Fake())
except wallpaper_visual.PickerError:
    assert mode == 'invalid'
else:
    assert mode != 'invalid'
    assert os.fsencode(result) == os.fsencode(path) if mode in ('confirm', 'filter') else result is None
'''
        for mode in ('confirm', 'filter', 'invalid', 'preview', 'close', 'empty', 'cancel', 'exit', 'random', 'escape', 'search', 'large'):
            with self.subTest(mode=mode):
                result = subprocess.run(['xvfb-run', '-a', sys.executable, '-c', program,
                                         str(SCRIPT.parent), mode, str(self.root)], env=env,
                                        capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))


if __name__ == '__main__':
    unittest.main()
