# Spanned-Background - Wallpaper Spanning

One wallpaper across every monitor, in the Omarchy shell. A drop-in
replacement for the stock background service.

<img src="docs/logo.svg" width="96" alt="Spanned Background's three monitors sharing one sunset, in 16 EGA colors">

![Three monitors of different sizes sharing one sunset wallpaper, edge to edge](preview.png)

The preview is an illustration, not a screenshot: the plugin draws no UI of
its own. What it changes is the wallpaper, which runs as one image across all
of your monitors instead of one copy per monitor.

The plugin works like the Windows "Span" wallpaper setting, for
[Omarchy](https://omarchy.org) **Quattro**. The image runs edge to edge with no
bezel compensation: the last pixel on the right of one monitor is followed
directly by the first pixel on the left of the next.

Everything the built-in `omarchy.background` service does keeps working:
`omarchy-theme-bg-set`, the `Super + Ctrl + Space` background picker, theme
switching with its diagonal wipe, and double-clicking the desktop. Video
wallpapers and theme intros span too. The manifest declares this plugin as a
clone of `omarchy.background`, which is how the shell finds the service it has
to watch when Omarchy's `owe` engine takes the desktop for a video.

## Requirements

- Omarchy 4.x ("Quattro"). This plugin targets the Quickshell-based
  `omarchy-shell` and does **not** work on Omarchy 3 or earlier.
- Two or more monitors to see any difference. With a single monitor it behaves
  exactly like the stock background service, and with no monitor connected at
  all it simply draws nothing (there is no window to draw into).
- No external packages. It uses only what Omarchy already ships, including
  `qt6-multimedia` for spanned video. Without that module, video falls back to
  `owe`'s per-monitor playback and stills are unaffected.

## Install

```bash
omarchy plugin disable omarchy.background
omarchy plugin add https://github.com/keasbeexd/omarchy-spanned-background --enable
```

Or manually, from a downloaded copy of this repository:

```bash
mkdir -p ~/.config/omarchy/plugins
cp -r omarchy-spanned-background ~/.config/omarchy/plugins/spanned-background
omarchy plugin validate ~/.config/omarchy/plugins/spanned-background
omarchy plugin disable omarchy.background
omarchy plugin enable keasbeexd.spanned-background
```

> [!IMPORTANT]
> **Disable `omarchy.background` first, in both cases.** Both plugins draw on
> the Wayland background layer and both claim the `background` IPC target, so
> running them together gives you two stacked wallpapers and an IPC conflict.

If the wallpaper does not change straight away, ask the shell to rescan:

```bash
omarchy-shell -q shell rescanPlugins
```

If that does not pick it up, restart the shell or log out and back in.

## Using it

Spanning is on by default. To flip it at runtime:

```bash
omarchy-shell -q background span off      # back to one image per monitor
omarchy-shell -q background span on
omarchy-shell -q background span toggle
```

The choice is saved to `~/.config/omarchy/spanned-background.conf` and read
back when the shell starts. Without that file the plugin uses the
`spanEnabled` default at the top of `SpannedBackground.qml`.

The desktop shortcuts are the same as stock:

| Action | Result |
| --- | --- |
| `Super + Ctrl + Space` | background picker |
| double-click the desktop | background picker |
| right-double-click the desktop | theme switcher |

## Removing

```bash
omarchy plugin disable keasbeexd.spanned-background
omarchy plugin enable omarchy.background
omarchy plugin remove keasbeexd.spanned-background     # if installed via git
```

`omarchy plugin remove` deletes the plugin directory and all bundled scripts.
It does **not** delete:

- `~/.config/omarchy/spanned-background.conf` — the one-line file holding
  `span=on` or `span=off`. Delete it manually if you want no trace.
- In the unlikely case the shell was killed in the middle of saving that file,
  a stray `~/.config/omarchy/.spanned-background.XXXXXXXXXX` temporary (same
  one-line content) can remain next to it. It is safe to delete.

Nothing else is left behind: no daemons, no systemd units, no udev rules, no
`sudoers` entries, no polkit actions, no cache directory, no state directory,
no keyring items, no packages installed, no shared configuration edited.

## How it works

The stock background service creates one background-layer window per screen
and fills each with `PreserveAspectCrop`, which is why every monitor gets its
own full copy of the image.

This plugin keeps one window per screen (that is how Wayland layer shells work)
but changes what each window draws:

1. On startup, and whenever a monitor is added, removed, moved, rotated or
   rescaled, it reads `x`, `y`, `width` and `height` from every `ShellScreen`.
2. It computes the bounding box of the whole virtual desktop.
3. It sizes each window's image to *that* box, shifted by the window's own
   screen origin, and clips it to the screen.

Each output therefore draws only its own slice of one shared image. Every
window asks for the same image at the same size, so Qt's pixmap cache keeps a
single decode for all of them. That decode is at the image's full size, because
one image covers the whole desktop, where the stock plugin decodes at each
screen's size. A large wallpaper therefore costs more memory here.

Hyprland places every output in one logical coordinate space, so this works
for mixed resolutions, mixed (including fractional) scale factors, portrait
monitors and stacked arrangements without anything hardcoded for a particular
setup.

The theme-change wipe is computed in that same virtual space and then shifted
into each output's local coordinates, so one diagonal sweeps continuously across
the whole desktop instead of each screen wiping independently.

If the compositor ever returns geometry that does not make sense, the plugin
falls back to stock per-monitor rendering rather than drawing something wrong.

This plugin started from Omarchy's own `omarchy.background` service, and
`omarchy.clonedFrom` in the manifest is how the shell finds it in that service's
place. The upstream it tracks is
[`shell/plugins/background/Background.qml`](https://github.com/omacom/omarchy/blob/ac2690cd7be4f47e4a255f5e2e78d904d436b068/shell/plugins/background/Background.qml)
at Omarchy v4.5.0, commit `ac2690cd7be4f47e4a255f5e2e78d904d436b068`. It differs
from that file in spanning, in its helpers in `bin/`, in input bounds on IPC, and
in the video layer described below. It decodes at full size rather than screen
size, as noted above.

## Notes and caveats

- **Aspect ratio.** The image is scaled to cover the whole virtual desktop and
  whatever overflows is cropped. Two 16:9 monitors side by side make a 32:9
  canvas, so an ordinary 16:9 wallpaper loses half its height (a quarter off
  the top and a quarter off the bottom); three make 48:9 and it loses two
  thirds. Ultrawide or panoramic wallpapers look much better. Nothing is ever
  stretched: the aspect ratio is always preserved.
- **Non-rectangular layouts.** If your monitors are not aligned (say one sits
  200px lower than the other), the bounding box includes an empty L-shaped
  region. That part of the image is not shown on any screen; the parts you can
  see still line up correctly.
- **Fractional scaling.** Alignment is computed in logical pixels, so on
  fractional scale factors the seam can land on a fractional device pixel. Any
  resulting misalignment is sub-pixel and not visible in practice.
- **Memory.** Spanning adds no decodes: every screen shares one cached decode
  of the image, exactly as the stock plugin does.

### Video

`owe` draws a separate copy of a video on each monitor and cannot crop it, so
while spanning is on this plugin plays the same file again, one player per
monitor, on a layer above `owe`'s. The players start together. The desktop only
hands over once every monitor has its first frame, so `owe`'s per-monitor
picture does not show. The video then fades in over the spanned still. Playback
stays silent and follows `owe`'s pause state, checked once a second. `owe` stops
answering during a session lock, so the lock is read from Hyprland instead.

A theme intro has one more step. The shell covers the desktop with the old
wallpaper, cropped per monitor, which would jump out of the span for about a
second. The cover belongs to the shell, so this plugin stands in front of it:
its windows stay mapped on the Background layer holding the current still, and
move to the Bottom layer as soon as Hyprland reports the cover. That leaves at
most about one frame of the cover visible at the start of a switch. Switching
again while a video plays freezes its current frame and fades the next video in
over it, and the layer fades out when it lets go.

- **It costs more than `owe` alone.** `owe` keeps decoding underneath, so a
  looping video decodes three times on two monitors, and `omarchy-shell` holds
  several hundred MB more while one plays. A theme intro pays this for a few
  seconds. A permanent video wallpaper pays it for as long as it is set.
- **The held still** keeps a second copy of the wallpaper on the GPU at all
  times, so that it is ready the moment the cover appears.
- **Fallback.** With one monitor, spanning off, QtMultimedia missing, or a file
  the player refuses, `owe` shows the video per monitor as usual. The first
  spanned frame has 1.5 seconds to arrive before that fallback.
- **The lock screen** is not spanned. It draws its own wallpaper on each
  monitor, on secure surfaces this plugin cannot reach or draw over.
- **Hotplug.** A monitor connected during a looping video joins from the start
  of the file, so it runs out of step until the video changes.
- **Monitor layouts.** Any mix of sizes, scales, rotations and positions spans,
  gaps included, using the same bounding box as the stills. That box has to be
  covered, so an unusual layout shows a smaller, more cropped part of the
  picture: see "Aspect ratio" under Notes and caveats.
- **Reloading.** The shell's plugin reload does not pick up edits to this
  plugin's QML. Use `omarchy-restart-shell` when changing it.

## What it does on your system

Omarchy plugins run unsandboxed inside the shell process, so here is the full
list of what this one touches. Apart from the wallpaper image and the video
`owe` is playing (both loaded by Qt, see below), every file read and every
command goes through a bundled bash helper in `bin/`. The QML never builds a shell string, and every helper is
started by absolute path with its arguments as separate argv elements.

- **Reads**, via `bin/resolve-bg`, the symlink Omarchy maintains at
  `~/.local/state/omarchy/current/background`. The helper caps `readlink`
  output at 4096 bytes, refuses anything that is not a regular file owned by
  the current user or by root (stock theme wallpapers live under
  `/usr/share/omarchy/themes/`), and rejects paths with control characters
  before the result reaches the wallpaper renderer.
- **Reads**, via `bin/read-conf`, `~/.config/omarchy/spanned-background.conf`
  using `dd iflag=nofollow,nonblock,count_bytes,fullblock bs=1` for at most 129
  bytes, so a symlink or FIFO planted at that name is refused rather than
  followed or blocked on.
- **Writes**, via `bin/write-conf`, the same file. The helper creates an
  unpredictable temporary with `mktemp` in the destination directory (mode 600
  from creation), writes and fsyncs the payload, `mv -f -T`s it over the
  destination and fsyncs the directory. A symlink planted at the destination
  is therefore *replaced* by `rename(2)` rather than written through. The
  value on argv is checked against the closed set `{on, off}` before the
  helper touches the filesystem.
- **Runs**, only when you double-click the desktop, the same two commands the
  stock plugin runs: `omarchy-theme-bg-switcher` / `omarchy-theme-bg-set` and
  `omarchy-theme-switcher` / `omarchy-theme-set`. Each picker runs under
  `timeout -k 2 600` (each setter under `timeout -k 2 30`) in `bin/pick-bg` /
  `bin/pick-theme`, in its own process group; when the shell stops the
  helper, the helper forwards the signal so the picker and everything it
  started exits too. The picker's output is capped at 4 KiB (measured in
  bytes), and control characters, relative wallpaper paths and theme names
  with a leading dash are rejected before it becomes an argv element of the
  setter.
- **Runs**, while `owe` holds the desktop and once at startup, `bin/owe-video`,
  which asks `/usr/bin/hyprctl` whether the session is locked, then
  `/usr/bin/owe` for `status` and `render-status`, each under a `timeout -k`.
  Each reply is capped and parsed by a fixed `jq` filter.
  The video path it returns must be absolute, free of control characters and
  backslashes, carry a video extension, and be a regular file owned by the
  current user or by root.
- The three file helpers (`resolve-bg`, `read-conf`, `write-conf`) run with a
  cleared environment holding only `HOME` and `PATH=/usr/bin`, and `owe-video`
  with those plus `XDG_RUNTIME_DIR` and `HYPRLAND_INSTANCE_SIGNATURE`, which it
  needs to find the `owe` and Hyprland sockets.
- **Reads** the video `owe` is playing, through Qt Multimedia, in the same
  shell process. Only a path from `bin/owe-video` reaches the player. Paths
  arriving over IPC do not.
- **Listens** to Hyprland's event socket, through Quickshell, for a layer named
  `omarchy-background` opening. That is how it finds the shell's theme cover. It
  acts on nothing else from that stream.
- **Reads** the wallpaper image itself, through Qt's image loader. Every
  path that reaches `Image.source`, whether it comes from `bin/resolve-bg` or
  arrives over IPC, must be an absolute path or `file://` URL, free of control
  characters and at most 4096 characters long.
- **No network access, no elevated privileges, no external packages**, and
  nothing outside `~/.config/omarchy/spanned-background.conf` is ever written
  (if `~/.config/omarchy` does not exist, the write helper creates it, mode
  700, so it has somewhere to put that file).

The `background` IPC target exposes `refresh`, `set`, `setInstant`,
`setSuspended`, `transition`, `themeTransition` and `prepare` (the same methods
as the stock service, so Omarchy's own tools keep working), plus `span`.
Without `setSuspended`, `owe` falls back to switching the built-in
`omarchy.background` back on in `shell.json`. It only hides or shows this
plugin's layer and starts or stops the spanned video described above, and
`prepare` accepts its path and does nothing with it. Every
other path argument goes through the check above. `span` accepts only
`on|off|toggle|true|false|1|0` or an empty string (toggle) and at most 32
characters. `themeTransition`'s two base64 payloads are each capped at
128 KiB decoded before they reach the theme loader.

## Issues

Bug reports and pull requests are welcome at
<https://github.com/keasbeexd/omarchy-spanned-background/issues>. Please include
your monitor layout (`hyprctl monitors -j`) and your Omarchy version.

## License

MIT — see [LICENSE](LICENSE).
