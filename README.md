# Spanned Background

An Omarchy **Quattro** shell plugin that treats all of your monitors as one
continuous canvas and paints a single wallpaper across them — the equivalent of
the Windows "Span" wallpaper fit. Edge to edge, no bezel compensation: the pixel
at the right edge of your left monitor is the pixel immediately left of the one
at the left edge of your right monitor.

It is a drop-in replacement for the built-in `omarchy.background` service, so
everything else keeps working: `omarchy-theme-bg-set`, the `Super + Ctrl + Space`
background picker, theme switching with its diagonal wipe, and double-clicking
the desktop.

## Requirements

Omarchy 4.x ("Quattro"). It relies on the Quickshell-based `omarchy-shell`, so it
does not work on Omarchy 3 or earlier.

## Install

```bash
# 1. Put the plugin where Omarchy looks for third-party plugins
mkdir -p ~/.config/omarchy/plugins
cp -r omarchy-spanned-background ~/.config/omarchy/plugins/spanned-background

# 2. Sanity-check the manifest
omarchy plugin validate ~/.config/omarchy/plugins/spanned-background

# 3. Turn off the stock background service, turn this one on
omarchy plugin disable omarchy.background
omarchy plugin enable net.ironinsights.spanned-background
```

If the wallpaper does not change immediately, ask the shell to rescan:

```bash
omarchy-shell -q shell rescanPlugins
```

…and if that does not pick it up, restart the shell (or just log out and back in).

**Step 3 is not optional.** Both plugins register the same `background` IPC
target and both draw on the background layer, so running them together gives you
two stacked wallpapers and an IPC conflict.

### Installing from git instead

Omarchy can install directly from a repository, which also gets you
`omarchy plugin update`:

```bash
cd omarchy-spanned-background && git init && git add . && git commit -m "Spanned Background"
# push to your own remote, then:
omarchy plugin add https://github.com/<you>/omarchy-spanned-background --enable
omarchy plugin disable omarchy.background
```

## Using it

Spanning is on by default. To flip it at runtime:

```bash
omarchy-shell -q background span off      # back to one image per monitor
omarchy-shell -q background span on
omarchy-shell -q background span toggle
```

The choice is written to `~/.config/omarchy/spanned-background.conf` and read
back at shell start. You can also edit `spanEnabled` at the top of
`SpannedBackground.qml` to change the default.

Everything else is unchanged:

- `Super + Ctrl + Space` — background picker
- double-click the desktop — background picker
- right-double-click the desktop — theme switcher

## Uninstall / revert

```bash
omarchy plugin disable net.ironinsights.spanned-background
omarchy plugin enable omarchy.background
```

## How it works

The stock background service creates one background-layer window per screen and
fills each with `PreserveAspectCrop` — which is why every monitor gets its own
full copy of the image.

This plugin keeps the one-window-per-screen structure (that is how Wayland layer
shells work) but changes what each window draws. On startup, and whenever a
monitor is added, removed, moved, rotated or rescaled, it reads `x`, `y`,
`width` and `height` from every `ShellScreen`, computes the bounding box of the
whole virtual desktop, and sizes each window's image to *that* box, offset by
the negative of its own screen origin. Each output therefore renders only its
slice of one shared image. Contents are clipped to the output, so no monitor
rasterises a texture bigger than itself.

Because Hyprland lays every output out in a single logical coordinate space,
this is automatically correct for mixed resolutions, mixed (including
fractional) scale factors, portrait monitors and stacked arrangements — nothing
is hardcoded about your setup.

The theme-change wipe is computed in that same virtual space and then shifted
into each output's local coordinates, so one diagonal sweeps continuously across
the whole desktop instead of each screen wiping independently.

If the compositor ever hands back geometry that does not make sense, the plugin
silently falls back to stock per-monitor rendering rather than drawing something
wrong.

## Notes and caveats

- **Aspect ratio.** The image is scaled to cover the full virtual desktop and
  the overflow is cropped. Two 16:9 monitors side by side make a 32:9 canvas, so
  a normal 16:9 wallpaper loses roughly the top and bottom half of itself.
  Ultrawide-sourced wallpapers look dramatically better. Nothing is stretched —
  aspect ratio is always preserved.
- **Non-rectangular layouts.** If your monitors are not aligned (say one sits
  200px lower than the other), the bounding box includes the empty L-shaped
  region. That area simply is not visible on any screen; the parts you can see
  still line up correctly.
- **Memory.** Each screen decodes the image once, exactly as the stock plugin
  does. Spanning does not increase the number of decodes.
- **Renaming.** If you publish this, change `id` in `manifest.json` to your own
  namespace and update the `omarchy plugin enable` command to match.

## License

MIT — see LICENSE.
