# Security policy

## Reporting a vulnerability

Please report privately, not in a public issue or pull request:

- Use GitHub's **Report a vulnerability** button on the Security tab of
  this repository (private vulnerability reporting):
  https://github.com/keasbeexd/omarchy-spanned-background/security/advisories/new

Include what you found, how to reproduce it, and which commit you tested. A
proof of concept helps; please test only on your own machine.

You can expect an acknowledgement within a week. Fixes for confirmed issues
are released as soon as they are ready, with an advisory that credits you
unless you ask not to be named.

## What counts

Spanned Background is an Omarchy shell plugin that replaces the stock
background service. It installs nothing and needs no root. Examples of what
we want to hear about:

- a way for a wallpaper path, an image file or a theme to make the plugin
  run a command, read a file outside what it shows, or write anything;
- anything that lets another account on the machine influence what the
  plugin loads.

## Supported versions

Only the latest commit on the default branch is supported: Omarchy installs
plugins from it and `omarchy-plugin-update` moves to its newest commit.
