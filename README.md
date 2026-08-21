# Spanned Background

An [Omarchy](https://omarchy.org) **Quattro** shell plugin that treats all of
your monitors as one continuous canvas and paints a single wallpaper across
them — the equivalent of the Windows "Span" wallpaper fit. Edge to edge, no
bezel compensation: the pixel at the right edge of your left monitor is the
pixel immediately left of the one at the left edge of your right monitor.

It is a drop-in replacement for the built-in `omarchy.background` service, so
everything else keeps working: `omarchy-theme-bg-set`, the `Super + Ctrl + Space`
background picker, theme switching with its diagonal wipe, and double-clicking
the desktop.

## Requirements

- Omarchy 4.x ("Quattro"). This plugin targets the Quickshell-based
  `omarchy-shell` and does **not** work on Omarchy 3 or earlier.
- Two or more monitors, obviously. With a single monitor it behaves exactly like
  the stock background service.
- No external packages. It uses only what Omarchy already ships.

## Install

```bash
omarchy plugin disable omarchy.background
omarchy plugin add https://github.com/keasbeexd/omarchy-spanned-background --enable
```

Or manually, without git:

```bash
mkdir -p ~/.config/omarchy/plugins
cp -r omarchy-spanned-background ~/.config/omarchy/plugins/spanned-background
omarchy plugin validate ~/.config/omarchy/plugins/spanned-background
omarchy plugin disable omarchy.background
omarchy plugin enable keasbeexd.spanned-background
```

Disable the built-in *first* in both cases: while the two are enabled together
they fight over the same IPC target.

If the wallpaper does not change immediately, ask the shell to rescan:

```bash
omarchy-shell -q shell rescanPlugins
```

…and if that does not pick it up, restart the shell or log out and back in.

> [!IMPORTANT]
> **Disabling `omarchy.background` is required, not optional.** Both plugins draw
> on the Wayland background layer and both claim the `background` IPC target, so
> running them together gives you two stacked wallpapers and an IPC conflict.

## Using it

Spanning is on by default. To flip it at runtime:

```bash
omarchy-shell -q background span off      # back to one image per monitor
omarchy-shell -q background span on
omarchy-shell -q background span toggle
```

The choice is written to `~/.config/omarchy/spanned-background.conf` and read
back when the shell starts. You can also change the `spanEnabled` default at the
top of `SpannedBackground.qml`.

Everything else is unchanged:

| Action | Result |
| --- | --- |
| `Super + Ctrl + Space` | background picker |
| double-click the desktop | background picker |
| right-double-click the desktop | theme switcher |

## Uninstall

```bash
omarchy plugin disable keasbeexd.spanned-background
omarchy plugin enable omarchy.background
omarchy plugin remove keasbeexd.spanned-background     # if installed via git
```

Removing the plugin leaves `~/.config/omarchy/spanned-background.conf` behind;
delete it if you want no trace.

## How it works

The stock background service creates one background-layer window per screen and
fills each with `PreserveAspectCrop` — which is why every monitor gets its own
full copy of the image.

This plugin keeps the one-window-per-screen structure (that is how Wayland layer
shells work) but changes what each window draws. On startup, and whenever a
monitor is added, removed, moved, rotated or rescaled, it reads `x`, `y`, `width`
and `height` from every `ShellScreen`, computes the bounding box of the whole
virtual desktop, and sizes each window's image to *that* box, offset by the
negative of its own screen origin. Each output therefore renders only its slice
of one shared image, clipped to its own bounds. Every panel asks for the same
image at the same size, so Qt's pixmap cache holds a single decode between them
— the same memory profile as the stock plugin.

Because Hyprland lays every output out in a single logical coordinate space,
this is automatically correct for mixed resolutions, mixed (including
fractional) scale factors, portrait monitors and stacked arrangements — nothing
is hardcoded about any particular setup.

The theme-change wipe is computed in that same virtual space and then shifted
into each output's local coordinates, so one diagonal sweeps continuously across
the whole desktop instead of each screen wiping independently.

If the compositor ever returns geometry that does not make sense, the plugin
falls back to stock per-monitor rendering rather than drawing something wrong.

## Notes and caveats

- **Aspect ratio.** The image is scaled to cover the full virtual desktop and
  the overflow is cropped. Two 16:9 monitors side by side make a 32:9 canvas, so
  an ordinary 16:9 wallpaper loses roughly its top and bottom thirds.
  Ultrawide-sourced wallpapers look dramatically better. Nothing is ever
  stretched — aspect ratio is always preserved.
- **Non-rectangular layouts.** If your monitors are not aligned (say one sits
  200px lower than the other), the bounding box includes the empty L-shaped
  region. That area is simply not visible on any screen; the parts you can see
  still line up correctly.
- **Fractional scaling.** Alignment is computed in logical pixels, so on
  fractional scale factors the seam can land on a fractional device pixel. Any
  resulting misalignment is sub-pixel and not visible in practice.
- **Memory.** Spanning adds no decodes: every screen shares one cached decode
  of the image, exactly as the stock plugin does.

## What it does on your system

Omarchy plugins run unsandboxed inside the shell process, so here is the full
list of what this one touches:

- **Reads** `~/.local/state/omarchy/current/background` (the symlink Omarchy
  already maintains) via `readlink`, and the wallpaper image itself.
- **Reads and writes** `~/.config/omarchy/spanned-background.conf`, a
  single-line file holding `span=on` or `span=off`.
- **Runs**, only when you double-click the desktop, the same two commands the
  stock plugin runs: `omarchy-theme-bg-switcher` / `omarchy-theme-bg-set` and
  `omarchy-theme-switcher` / `omarchy-theme-set`.
- **No network access, no elevated privileges, no external dependencies**, and
  nothing outside `~/.config/omarchy` is ever written.

## Issues

Bug reports and pull requests are welcome at
<https://github.com/keasbeexd/omarchy-spanned-background/issues>. Please include
your monitor layout (`hyprctl monitors -j`) and your Omarchy version.

## License

MIT — see [LICENSE](LICENSE).
