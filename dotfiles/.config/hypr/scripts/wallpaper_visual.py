#!/usr/bin/env python3
import collections
import concurrent.futures
from dataclasses import dataclass
import os
from pathlib import Path
import random
import resource
import selectors
import signal
import stat
import struct
import subprocess
import sys
import threading
import time


MAX_INPUT = 32 * 1024 * 1024
MAX_PIXELS = 80_000_000
MAX_WIDTH = 512
MAX_HEIGHT = 320
MAX_OUTPUT = MAX_WIDTH * MAX_HEIGHT * 4
MAX_PENDING = 4
MAX_WORKERS = 2
MAX_CACHE = 48
TIMEOUT = 5
HEADER = struct.Struct('!4sIII')
EXTENSIONS = frozenset({'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif', '.tiff'})
BROWSER_CSS = b'''
    .wallpaper-browser { background-color: #1f2225; color: #eeeeee; }
    .wallpaper-browser button { background: #292d31; color: #eeeeee;
        border: 1px solid #484d52; border-radius: 4px; padding: 6px 10px; }
    .wallpaper-browser button:hover { background: #383e43; }
    .wallpaper-browser button:disabled { opacity: 0.45; }
    .wallpaper-browser button.suggested-action { background: #267fae; }
    .wallpaper-browser entry { background: #151719; color: #eeeeee;
        border: 1px solid #484d52; border-radius: 4px; }
    .wallpaper-browser gridview { background: transparent; }
    .wallpaper-browser gridview > child { border: 1px solid transparent;
        border-radius: 4px; padding: 4px; }
    .wallpaper-browser gridview > child:selected { background: #303941;
        border-color: #36b9ff; }
'''


@dataclass(frozen=True)
class Candidate:
    path: Path
    directory: bool


class Browser:
    def __init__(self, root):
        self.root = Path(root).resolve(strict=True)
        if not self.root.is_dir():
            raise PickerError('Wallpaper folder is unavailable')
        self.current = ()
        self.history = []

    @staticmethod
    def validate(parts):
        parts = tuple(parts)
        if any(not part or part in ('.', '..') or '/' in part or '\0' in part for part in parts):
            raise PickerError('Invalid folder selection')
        return parts

    def move(self, parts, remember=True):
        parts = self.validate(parts)
        if remember and self.current != parts:
            self.history.append(self.current)
        self.current = parts

    def back(self):
        if self.history:
            self.move(self.history.pop(), remember=False)

    def scan(self, parts):
        parts = self.validate(parts)
        descriptor = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            for part in parts:
                next_descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                          dir_fd=descriptor)
                os.close(descriptor)
                descriptor = next_descriptor
            entries = []
            with os.scandir(descriptor) as listing:
                for entry in listing:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            directory = True
                        elif (entry.is_file(follow_symlinks=False)
                              and Path(entry.name.rstrip()).suffix.lower() in EXTENSIONS):
                            directory = False
                        else:
                            continue
                        entries.append(Candidate(self.root.joinpath(*parts, entry.name), directory))
                    except OSError:
                        continue
            return tuple(sorted(entries, key=lambda item: (not item.directory, item.path.name)))
        finally:
            os.close(descriptor)


class PickerError(Exception):
    pass


def display_name(path):
    result = []
    for character in os.fsdecode(os.fsencode(Path(path).name)):
        number = ord(character)
        if character == '\\':
            result.append('\\\\')
        elif 0xDC80 <= number <= 0xDCFF:
            result.append(f'\\x{number - 0xDC00:02x}')
        elif not character.isprintable():
            result.append(character.encode('unicode_escape').decode('ascii'))
        else:
            result.append(character)
    return ''.join(result)


def thumbnail():
    for kind, maximum in ((resource.RLIMIT_AS, 512 * 1024 * 1024), (resource.RLIMIT_CPU, 4)):
        soft, hard = resource.getrlimit(kind)
        limit = min(value for value in (soft, hard, maximum) if value != resource.RLIM_INFINITY)
        resource.setrlimit(kind, (limit, limit))
    import gi
    gi.require_version('GdkPixbuf', '2.0')
    from gi.repository import GdkPixbuf

    name = sys.stdin.buffer.read(65537)
    if not name or len(name) > 65536 or b'\0' in name:
        return 1
    descriptor = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_INPUT:
            return 1
        loader = GdkPixbuf.PixbufLoader.new()
        dimensions = []

        def sized(image, width, height):
            dimensions.append((width, height))
            if width <= 0 or height <= 0 or width * height > MAX_PIXELS:
                image.set_size(1, 1)
            else:
                scale = min(MAX_WIDTH / width, MAX_HEIGHT / height, 1)
                image.set_size(max(1, int(width * scale)), max(1, int(height * scale)))

        loader.connect('size-prepared', sized)
        total = 0
        while True:
            data = os.read(descriptor, min(65536, MAX_INPUT + 1 - total))
            if not data:
                break
            total += len(data)
            if total > MAX_INPUT:
                return 1
            loader.write(data)
            if dimensions and dimensions[0][0] * dimensions[0][1] > MAX_PIXELS:
                return 1
        loader.close()
        image = loader.get_pixbuf()
        if image is None or not dimensions or dimensions[0][0] * dimensions[0][1] > MAX_PIXELS:
            return 1
        if not image.get_has_alpha():
            image = image.add_alpha(False, 0, 0, 0)
        width, height = image.get_width(), image.get_height()
        rowstride = image.get_rowstride()
        pixels = bytes(image.get_pixels())
        if not (0 < width <= MAX_WIDTH and 0 < height <= MAX_HEIGHT and rowstride >= width * 4):
            return 1
        raw = b''.join(pixels[row * rowstride:row * rowstride + width * 4] for row in range(height))
        if len(raw) != width * height * 4:
            return 1
        sys.stdout.buffer.write(HEADER.pack(b'RGBA', width, height, len(raw)) + raw)
        return 0
    finally:
        os.close(descriptor)


def decode_frame(data):
    if len(data) < HEADER.size or len(data) > HEADER.size + MAX_OUTPUT:
        return None
    magic, width, height, length = HEADER.unpack_from(data)
    if (magic != b'RGBA' or not 0 < width <= MAX_WIDTH or not 0 < height <= MAX_HEIGHT
            or length != width * height * 4 or len(data) != HEADER.size + length):
        return None
    return width, height, data[HEADER.size:]


class PreviewPool:
    def __init__(self, callback):
        self.callback = callback
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS)
        self.lock = threading.Lock()
        self.processes = set()
        self.closed = False
        self.pending = set()
        self.futures = {}

    def request(self, index, path):
        if self.closed or index in self.pending or len(self.pending) >= MAX_PENDING:
            return False
        self.pending.add(index)
        future = self.executor.submit(self.run, os.fsencode(path))
        self.futures[index] = future
        future.add_done_callback(lambda result: self.callback(index, result))
        return True

    def invalidate(self):
        with self.lock:
            for future in self.futures.values():
                future.cancel()
            for process in self.processes:
                self.kill(process)

    def complete(self, index):
        self.pending.discard(index)
        self.futures.pop(index, None)

    def run(self, path):
        if not path or len(path) > 65536 or b'\0' in path:
            return None
        with self.lock:
            if self.closed:
                return None
            process = subprocess.Popen([sys.executable, __file__, '--thumbnail'], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
            self.processes.add(process)
        try:
            deadline = time.monotonic() + TIMEOUT
            output = bytearray()
            offset = 0
            os.set_blocking(process.stdin.fileno(), False)
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                selector.register(process.stdin, selectors.EVENT_WRITE)
                while True:
                    remaining = deadline - time.monotonic()
                    events = selector.select(max(0, remaining))
                    if remaining <= 0 or not events:
                        raise subprocess.TimeoutExpired(process.args, TIMEOUT)
                    finished = False
                    for key, _events in events:
                        if key.fileobj is process.stdin:
                            offset += os.write(process.stdin.fileno(), path[offset:])
                            if offset == len(path):
                                selector.unregister(process.stdin)
                                process.stdin.close()
                        else:
                            data = os.read(process.stdout.fileno(), min(65536, HEADER.size + MAX_OUTPUT + 1 - len(output)))
                            if not data:
                                finished = True
                                break
                            output.extend(data)
                            if len(output) > HEADER.size + MAX_OUTPUT:
                                return None
                    if finished:
                        break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(process.args, TIMEOUT)
            return decode_frame(output) if process.wait(timeout=remaining) == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            return None
        finally:
            if process.poll() is None:
                self.kill(process)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            process.stdin.close()
            process.stdout.close()
            with self.lock:
                self.processes.discard(process)

    @staticmethod
    def kill(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def close(self):
        with self.lock:
            self.closed = True
            for process in self.processes:
                self.kill(process)
        self.executor.shutdown(wait=True, cancel_futures=True)


def pick_wallpaper(wallpaper, visual_only=False):
    if getattr(wallpaper, 'verbose', False):
        return run_picker(wallpaper, visual_only=visual_only) if visual_only else run_picker(wallpaper)
    saved = os.dup(2)
    try:
        with open(os.devnull, 'wb') as sink:
            os.dup2(sink.fileno(), 2)
            return run_picker(wallpaper, visual_only=visual_only) if visual_only else run_picker(wallpaper)
    finally:
        os.dup2(saved, 2)
        os.close(saved)


def run_picker(wallpaper, visual_only=False):
    try:
        import gi
        gi.require_version('Gtk', '4.0')
        gi.require_version('Gdk', '4.0')
        from gi.repository import Gdk, Gio, GLib, GObject, Gtk
    except (ImportError, ValueError) as error:
        raise PickerError('GTK 4 and Python GObject bindings are required') from error
    if not Gtk.init_check() or Gdk.Display.get_default() is None:
        raise PickerError('Unable to initialize the graphical wallpaper picker')

    class Item(GObject.Object):
        def __init__(self, index, candidate):
            super().__init__()
            self.index = index
            self.directory = candidate.directory
            self.label = display_name(candidate.path)

    class Window:
        def __init__(self):
            self.closed = False
            self.failure = None
            self.result = None
            self.browser = Browser(wallpaper.wallpaper_folder())
            self.generation = 0
            self.scan_condition = threading.Condition()
            self.scan_request = None
            self.paths = ()
            self.incomplete = False
            self.cache = collections.OrderedDict()
            self.visible = {}
            self.loop = GLib.MainLoop()
            self.window = Gtk.Window(title='Choose wallpaper')
            self.window.set_default_size(1000, 700)
            self.window.connect('close-request', self.cancel)
            self.pool = PreviewPool(self.preview_done)
            self.style = Gtk.CssProvider()
            self.style.load_from_data(BROWSER_CSS)
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), self.style,
                                                      Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
            root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            root.add_css_class('wallpaper-browser')
            for side in ('top', 'bottom', 'start', 'end'):
                getattr(root, 'set_margin_' + side)(12)
            self.window.set_child(root)
            toolbar = Gtk.Box(spacing=8)
            folder_button = Gtk.ToggleButton(label='Folder')
            folder_button.set_active(True)
            toolbar.append(folder_button)
            self.search = Gtk.SearchEntry(placeholder_text='Search this folder')
            self.search.set_hexpand(True)
            toolbar.append(self.search)
            clear_search = Gtk.Button(label='Clear')
            clear_search.connect('clicked', lambda *_: self.search.set_text(''))
            toolbar.append(clear_search)
            refresh = Gtk.Button(label='Refresh')
            refresh.connect('clicked', lambda *_: self.navigate(self.browser.current, remember=False, reset_search=False))
            toolbar.append(refresh)
            random_button = Gtk.Button(label='Random')
            random_button.set_tooltip_text('Select a random image in this folder without applying it')
            random_button.connect('clicked', self.select_random)
            toolbar.append(random_button)
            exit_button = Gtk.Button(label='Exit')
            exit_button.connect('clicked', self.cancel)
            toolbar.append(exit_button)
            root.append(toolbar)
            navigation = Gtk.Box(spacing=6)
            self.back_button = Gtk.Button(label='Back')
            self.back_button.connect('clicked', self.go_back)
            navigation.append(self.back_button)
            self.up_button = Gtk.Button(label='Up')
            self.up_button.connect('clicked', self.go_up)
            navigation.append(self.up_button)
            home = Gtk.Button(label='Root')
            home.connect('clicked', lambda *_: self.navigate(()))
            navigation.append(home)
            self.breadcrumbs = Gtk.Box(spacing=3)
            breadcrumb_scroll = Gtk.ScrolledWindow()
            breadcrumb_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
            breadcrumb_scroll.set_hexpand(True)
            breadcrumb_scroll.set_child(self.breadcrumbs)
            navigation.append(breadcrumb_scroll)
            navigation_revealer = Gtk.Revealer()
            navigation_revealer.set_child(navigation)
            navigation_revealer.set_reveal_child(True)
            folder_button.connect('toggled', lambda button: navigation_revealer.set_reveal_child(button.get_active()))
            root.append(navigation_revealer)
            self.message = Gtk.Label(label='Finding wallpapers…', xalign=0)
            root.append(self.message)
            self.store = Gio.ListStore.new(Item)
            self.filter = Gtk.CustomFilter.new(self.matches)
            filtered = Gtk.FilterListModel.new(self.store, self.filter)
            self.selection = Gtk.SingleSelection.new(filtered)
            self.selection.set_autoselect(False)
            self.selection.set_can_unselect(True)
            self.search.connect('changed', self.search_changed)
            factory = Gtk.SignalListItemFactory()
            factory.connect('setup', self.setup)
            factory.connect('bind', self.bind)
            factory.connect('unbind', self.unbind)
            grid = Gtk.GridView.new(self.selection, factory)
            grid.set_min_columns(1)
            grid.set_max_columns(4)
            grid.connect('activate', self.activate)
            scroll = Gtk.ScrolledWindow()
            scroll.set_vexpand(True)
            scroll.set_child(grid)
            content = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
            content.set_start_child(scroll)
            content.set_resize_start_child(True)
            content.set_shrink_start_child(False)
            preview_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            preview_box.set_size_request(220, -1)
            preview_box.set_visible(False)
            self.preview_box = preview_box
            self.preview = Gtk.Picture()
            self.preview.set_size_request(200, 180)
            self.preview.set_can_shrink(True)
            self.preview.set_vexpand(True)
            preview_overlay = Gtk.Overlay()
            preview_placeholder = Gtk.Image.new_from_icon_name('image-missing-symbolic')
            preview_placeholder.set_pixel_size(64)
            preview_overlay.set_child(preview_placeholder)
            preview_overlay.add_overlay(self.preview)
            preview_overlay.set_vexpand(True)
            preview_box.append(preview_overlay)
            self.preview_label = Gtk.Label(label='Select an image to preview', wrap=True)
            preview_box.append(self.preview_label)
            content.set_end_child(preview_box)
            content.set_vexpand(True)
            root.append(content)
            controls = Gtk.Box(spacing=8, halign=Gtk.Align.END)
            self.clear = Gtk.Button(label='Clear selection')
            self.clear.set_sensitive(False)
            self.clear.connect('clicked', self.clear_selection)
            controls.append(self.clear)
            cancel = Gtk.Button(label='Cancel')
            cancel.connect('clicked', self.cancel)
            controls.append(cancel)
            self.apply = Gtk.Button(label='Apply wallpaper')
            self.apply.add_css_class('suggested-action')
            self.apply.set_sensitive(False)
            self.apply.connect('clicked', self.confirm)
            controls.append(self.apply)
            if visual_only:
                self.apply.set_tooltip_text('Disabled during visual review')
            root.append(controls)
            self.selection.connect('notify::selected-item', self.selection_changed)
            keys = Gtk.EventControllerKey()
            keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            keys.connect('key-pressed', self.key_pressed)
            self.window.add_controller(keys)

        def matches(self, item, *_):
            return self.search.get_text().casefold() in item.label.casefold()

        def search_changed(self, *_):
            self.selection.set_selected(Gtk.INVALID_LIST_POSITION)
            self.filter.changed(Gtk.FilterChange.DIFFERENT)
            self.update_message()

        def update_message(self):
            if self.paths:
                if not self.selection.get_n_items():
                    self.message.set_label('No wallpapers match your search.')
                else:
                    self.message.set_label('Some folders could not be read.' if self.incomplete else '')

        def selection_changed(self, *_):
            item = self.selection.get_selected_item()
            selected = item is not None
            self.apply.set_sensitive(selected and not item.directory and not visual_only)
            self.clear.set_sensitive(selected)
            self.preview_box.set_visible(selected and not item.directory)
            self.preview.set_paintable(None)
            if selected and not item.directory:
                self.preview_label.set_label(item.label)
                self.show_picture((self.generation, item.index), self.preview)
                self.refill()
            else:
                self.preview_label.set_label('Folder' if selected else 'Select an image to preview')

        def clear_selection(self, *_):
            self.selection.set_selected(Gtk.INVALID_LIST_POSITION)

        def select_random(self, *_):
            choices = [position for position in range(self.selection.get_n_items())
                       if not self.selection.get_item(position).directory]
            if choices:
                self.selection.set_selected(random.SystemRandom().choice(choices))

        def setup(self, _factory, row):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            box.set_margin_top(6)
            box.set_margin_bottom(6)
            box.set_margin_start(6)
            box.set_margin_end(6)
            image = Gtk.Picture()
            image.set_size_request(230, 145)
            image.set_can_shrink(True)
            placeholder = Gtk.Image.new_from_icon_name('image-missing-symbolic')
            placeholder.set_pixel_size(40)
            overlay = Gtk.Overlay()
            overlay.set_child(placeholder)
            overlay.add_overlay(image)
            box.append(overlay)
            label = Gtk.Label(xalign=0)
            label.set_ellipsize(3)
            label.set_max_width_chars(24)
            box.append(label)
            row.set_child(box)

        def bind(self, _factory, row):
            item = row.get_item()
            box = row.get_child()
            box.set_tooltip_text(item.label)
            overlay = box.get_first_child()
            picture = overlay.get_last_child()
            icon = overlay.get_first_child()
            icon.set_from_icon_name('folder-symbolic' if item.directory else 'image-missing-symbolic')
            overlay.get_next_sibling().set_label(item.label)
            overlay.get_next_sibling().set_visible(item.directory)
            key = (self.generation, item.index)
            if item.directory:
                picture.set_paintable(None)
                self.visible.pop(id(row), None)
            else:
                self.visible[id(row)] = (key, picture)
                self.show_picture(key, picture)
            self.refill()

        def unbind(self, _factory, row):
            self.visible.pop(id(row), None)

        def show_picture(self, index, picture):
            frame = self.cache.get(index)
            if frame:
                width, height, pixels = frame
                texture = Gdk.MemoryTexture.new(width, height, Gdk.MemoryFormat.R8G8B8A8,
                                                GLib.Bytes.new(pixels), width * 4)
                picture.set_paintable(texture)
                picture.set_tooltip_text(None)
                self.cache.move_to_end(index)
            else:
                picture.set_paintable(None)
                picture.set_tooltip_text('Preview unavailable or loading')

        def refill(self):
            keys = [key for key, _picture in self.visible.values()]
            item = self.selection.get_selected_item()
            if item is not None and not item.directory:
                keys.insert(0, (self.generation, item.index))
            for key in keys:
                generation, index = key
                if generation == self.generation and index < len(self.paths) and key not in self.cache:
                    self.pool.request(key, self.paths[index].path)

        def preview_done(self, index, future):
            GLib.idle_add(self.finish_preview, index, future)

        def finish_preview(self, index, future):
            if self.closed:
                return False
            self.pool.complete(index)
            if index[0] != self.generation:
                self.refill()
                return False
            try:
                frame = future.result()
            except Exception:
                frame = None
            self.cache[index] = frame or False
            self.cache.move_to_end(index)
            while len(self.cache) > MAX_CACHE:
                self.cache.popitem(last=False)
            for visible_index, picture in self.visible.values():
                if visible_index == index:
                    self.show_picture(index, picture)
            selected = self.selection.get_selected_item()
            if selected is not None and not selected.directory and (self.generation, selected.index) == index:
                self.show_picture(index, self.preview)
            self.refill()
            return False

        def discovered(self, generation, paths, error):
            if self.closed or generation != self.generation:
                return False
            if error:
                self.paths = ()
                self.message.set_label('This folder could not be read.')
                return False
            self.paths = tuple(paths)
            GLib.idle_add(self.populate, generation, 0)
            self.message.set_label('' if self.paths else 'This folder is empty.')
            return False

        def populate(self, generation, offset):
            if self.closed or generation != self.generation or offset >= len(self.paths):
                return False
            end = min(offset + 64, len(self.paths))
            self.store.splice(offset, 0, [Item(index, self.paths[index]) for index in range(offset, end)])
            if end < len(self.paths):
                GLib.idle_add(self.populate, generation, end)
            else:
                self.update_message()
            return False

        def find_images(self):
            while True:
                with self.scan_condition:
                    while self.scan_request is None and not self.closed:
                        self.scan_condition.wait()
                    if self.closed:
                        return
                    generation, parts = self.scan_request
                    self.scan_request = None
                try:
                    paths = self.browser.scan(parts)
                    GLib.idle_add(self.discovered, generation, paths, False)
                except Exception:
                    GLib.idle_add(self.discovered, generation, (), True)

        def navigate(self, parts, remember=True, reset_search=True):
            self.browser.move(parts, remember=remember)
            self.generation += 1
            self.pool.invalidate()
            self.selection.set_selected(Gtk.INVALID_LIST_POSITION)
            self.store.remove_all()
            self.visible.clear()
            self.paths = ()
            if reset_search:
                self.search.set_text('')
            self.message.set_label('Loading folder…')
            self.back_button.set_sensitive(bool(self.browser.history))
            self.up_button.set_sensitive(bool(self.browser.current))
            while child := self.breadcrumbs.get_first_child():
                self.breadcrumbs.remove(child)
            parts = self.browser.current
            for depth, label in enumerate(('Wallpapers', *(display_name(part) for part in parts))):
                button = Gtk.Button(label=label)
                button.connect('clicked', lambda _button, target=parts[:depth]: self.navigate(target))
                self.breadcrumbs.append(button)
            with self.scan_condition:
                self.scan_request = (self.generation, parts)
                self.scan_condition.notify()

        def go_back(self, *_):
            if self.browser.history:
                self.browser.back()
                self.navigate(self.browser.current, remember=False)

        def go_up(self, *_):
            if self.browser.current:
                self.navigate(self.browser.current[:-1])

        def activate(self, _grid, position):
            self.selection.set_selected(position)
            item = self.selection.get_selected_item()
            if item is not None and item.directory and 0 <= item.index < len(self.paths):
                self.navigate((*self.browser.current, self.paths[item.index].path.name))

        def confirm(self, *_):
            if visual_only:
                return
            item = self.selection.get_selected_item()
            if item is None or item.directory:
                return
            if (type(item.index) is not int or not 0 <= item.index < len(self.paths)
                    or self.paths[item.index].directory):
                self.failure = 'Invalid wallpaper picker selection'
            else:
                self.result = self.paths[item.index].path
            self.cancel()

        def key_pressed(self, _controller, key, _code, state):
            if key == Gdk.KEY_Escape:
                self.cancel()
                return True
            if key == Gdk.KEY_Left and state & Gdk.ModifierType.ALT_MASK:
                self.go_back()
                return True
            return False

        def cancel(self, *_):
            if not self.closed:
                self.closed = True
                self.window.set_visible(False)
                with self.scan_condition:
                    self.scan_condition.notify()
                self.pool.close()
                self.loop.quit()
            return True

        def run(self):
            try:
                threading.Thread(target=self.find_images, daemon=True).start()
                self.navigate((), remember=False)
                self.window.present()
                self.loop.run()
            finally:
                if not self.closed:
                    self.cancel()
                self.window.destroy()
                Gtk.StyleContext.remove_provider_for_display(Gdk.Display.get_default(), self.style)
            if self.failure:
                raise PickerError(self.failure)
            return self.result

    window = None
    previous_hook = sys.excepthook

    def callback_failure(_kind, _error, _traceback):
        if window is not None:
            window.failure = 'The graphical wallpaper picker failed'
            GLib.idle_add(window.cancel)

    try:
        window = Window()
        sys.excepthook = callback_failure
        return window.run()
    except PickerError:
        raise
    except Exception as error:
        raise PickerError('The graphical wallpaper picker failed') from error
    finally:
        sys.excepthook = previous_hook


if __name__ == '__main__':
    try:
        sys.exit(thumbnail() if sys.argv[1:] == ['--thumbnail'] else 2)
    except Exception:
        sys.exit(1)
