import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// Spanned Background
//
// A drop-in replacement for the built-in `omarchy.background` service that
// treats every connected monitor as one continuous canvas and paints a single
// wallpaper across all of them (the equivalent of Windows' "Span" fit).
//
// It keeps the stock behaviour otherwise: the same `background` IPC surface,
// the same diagonal wipe on theme change (now sweeping across the whole
// desktop rather than restarting on each screen), and the same double-click
// shortcuts to the background / theme switchers.
Item {
  id: root

  // ---------------------------------------------------------------------
  // Settings. `span` is also persisted in ~/.config/omarchy/spanned-background.conf
  // and can be flipped at runtime:  omarchy-shell -q background span toggle
  // ---------------------------------------------------------------------
  property bool spanEnabled: true          // false => stock one-image-per-monitor
  readonly property real revealSlant: -0.18 // diagonal of the theme-change wipe

  readonly property string home: Quickshell.env("HOME")

  // Absolute filesystem path of the directory this QML file lives in, so every
  // bundled helper is invoked by a fully-qualified path rather than a name
  // resolved through the caller's PATH. `Qt.resolvedUrl(".")` gives a file://
  // URL; strip the scheme and the trailing slash.
  readonly property string pluginDir: {
    var s = Qt.resolvedUrl(".").toString()
    if (s.substring(0, 7) === "file://") s = s.substring(7)
    if (s.length > 0 && s.charAt(s.length - 1) === "/") s = s.substring(0, s.length - 1)
    return s
  }
  readonly property string helperBin: pluginDir + "/bin"

  // Hard caps on strings that arrive via IPC. A wallpaper path is bounded by
  // PATH_MAX and no legitimate theme payload is anywhere near this size; a
  // caller that exceeds either gets their call refused rather than the shell
  // process allocating a large string on their behalf.
  readonly property int maxPathBytes: 4096
  readonly property int maxThemePayloadBytes: 131072   // 128 KiB per decoded payload

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1
  // True while owe's renderer covers the desktop: at login, and for a video.
  // The shell's theme cover waits on this, so with spanned video it turns true
  // at the first spanned frame rather than at owe's handoff.
  property bool suspended: false
  // owe has taken the desktop. See setOweActive.
  property bool oweActive: false
  // What the spanned video layer plays, reported by bin/owe-video.
  property string videoPath: ""
  property string videoRefused: ""
  // The video layer is up showing heldStill, for the video to fade in over.
  // That still is the desktop's own, kept current so it is ready when needed.
  property bool holding: false
  property string heldStill: ""
  // A theme cover is up, so the layer in front of it has to stay until the next
  // video has frames, whatever owe does in between.
  property bool coverPending: false
  // A video in front of it hides any change, so only a bare hold pins the still.
  onDisplayedBackgroundChanged: if ((!holding || videoPath) && !isVideo(displayedBackground)) heldStill = displayedBackground
  property bool videoProbe: true
  property bool videoLoop: false
  property bool videoPaused: false
  readonly property bool canSpanVideo: videoLoader.status === Loader.Ready
  onCanSpanVideoChanged: if (oweActive) setOweActive(true)

  // The shell's startup cover waits on this. A video is OWE's to draw, so it
  // has nothing to wait for here.
  readonly property bool ready: {
    if (isVideo(displayedBackground)) return true
    if (backgrounds.instances.length === 0) return false
    for (var i = 0; i < backgrounds.instances.length; i++) {
      if (!backgrounds.instances[i].backgroundReady) return false
    }
    return true
  }

  // Bounding box of every output, in compositor logical coordinates. Because
  // Hyprland lays every monitor out in one logical coordinate space, this works
  // for mixed resolutions, mixed scale factors and rotated panels alike.
  property real virtualX: 0
  property real virtualY: 0
  property real virtualWidth: 0
  property real virtualHeight: 0
  property bool geometryValid: false

  readonly property bool spanning: spanEnabled && geometryValid

  // owe plays video wallpapers on its own layer; this one draws stills.
  function isVideo(path) {
    return /\.(mp4|m4v|mov|webm|mkv|avi)$/i.test(String(path || ""))
  }

  function imageUrl(path) {
    if (isVideo(path)) return ""
    // A path that already is a file:// URL goes straight through: Util.fileUrl
    // prepends the scheme unconditionally, so handing it one would produce
    // file://file:///... and Image.source would resolve nothing. An absolute
    // path is the other accepted form -- see normalisePath.
    if (path.substring(0, 7) === "file://") return path
    return Util.fileUrl(path)
  }

  function mediaUrl(path) {
    if (path.substring(0, 7) === "file://") return path
    return Util.fileUrl(path)
  }

  function isNum(v) {
    return typeof v === "number" && isFinite(v)
  }

  // Path arriving via IPC or via helper stdout. Legitimate wallpaper paths are
  // short absolute filesystem paths or `file://` URLs; anything else -- an
  // http(s)/data/qrc URL, a relative path, embedded control characters, or a
  // string too long to be a real path -- would let a same-UID caller steer
  // Image.source through Qt's URL layer to fetch remote content, decode a
  // hostile SVG, or block on a FIFO. Reject rather than sanitise.
  function normalisePath(p) {
    if (typeof p !== "string") return ""
    var s = p
    // Trim ASCII whitespace only; do not touch the interior.
    while (s.length > 0 && (s.charAt(0) === " " || s.charAt(0) === "\t" || s.charAt(0) === "\n" || s.charAt(0) === "\r")) s = s.substring(1)
    while (s.length > 0) {
      var c = s.charAt(s.length - 1)
      if (c !== " " && c !== "\t" && c !== "\n" && c !== "\r") break
      s = s.substring(0, s.length - 1)
    }
    if (s.length === 0 || s.length > maxPathBytes) return ""
    for (var i = 0; i < s.length; i++) {
      var code = s.charCodeAt(i)
      if (code < 0x20 || (code >= 0x7f && code <= 0x9f)) return ""
    }
    var body = s
    if (s.substring(0, 7) === "file://") body = s.substring(7)
    else if (s.charAt(0) !== "/") return ""
    // Absolute paths only. Do not attempt to canonicalise here; the caller
    // will hand this off to Image.source, which will treat the string as a
    // filesystem path and fail closed on anything the FS refuses.
    if (body.length === 0 || body.charAt(0) !== "/") return ""
    return s
  }

  function recomputeGeometry() {
    var screens = Quickshell.screens
    if (!screens || screens.length === 0) {
      geometryValid = false
      return
    }

    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    var seen = 0

    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      if (!s) continue
      if (!isNum(s.x) || !isNum(s.y) || !isNum(s.width) || !isNum(s.height)) continue
      if (s.width <= 0 || s.height <= 0) continue
      minX = Math.min(minX, s.x)
      minY = Math.min(minY, s.y)
      maxX = Math.max(maxX, s.x + s.width)
      maxY = Math.max(maxY, s.y + s.height)
      seen++
    }

    // If the compositor did not hand us usable geometry, fall back to stock
    // per-monitor rendering rather than painting something wrong.
    if (seen === 0 || !isFinite(minX) || !isFinite(minY) || maxX <= minX || maxY <= minY) {
      geometryValid = false
      return
    }

    virtualX = minX
    virtualY = minY
    virtualWidth = maxX - minX
    virtualHeight = maxY - minY
    geometryValid = true
  }

  function scheduleGeometryUpdate() {
    recomputeGeometry()
    geometryTimer.restart()
  }

  function refreshBackground() {
    if (!resolveBgProc.running) {
      resolveBgProc.buffer = ""
      resolveBgProc.overflow = false
      resolveBgProc.running = true
    }
  }

  function setBackground(path, instant) {
    var clean = normalisePath(path)
    if (!clean) return
    transitionBackground("", clean, clean, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    var cleanPath = normalisePath(path)
    if (!cleanPath) return
    var cleanFinal = finalPath ? normalisePath(finalPath) : cleanPath
    if (!cleanFinal) cleanFinal = cleanPath
    var cleanFrom = normalisePath(fromPath) // may be empty; that is fine

    if (!force && cleanFinal === currentBackground) return
    currentBackground = cleanFinal
    backgroundVersion += 1
    revealStartedVersion = -1

    // OWE fades the last still into a video, so that still stays up until OWE
    // has its first frame and suspends this layer. Dropping it now would leave
    // the desktop empty in between. A running wipe finishes on its incoming
    // still for the same reason.
    if (!instant && !suspended && displayedBackground && isVideo(cleanPath) && !isVideo(displayedBackground)) return

    revealAnimation.stop()
    finishingTransition = false

    // The wipe is image-only, so a video on either side of it switches at once.
    if (instant || !displayedBackground || isVideo(cleanPath) || isVideo(displayedBackground)) {
      oldBackground = ""
      incomingBackground = ""
      displayedBackground = cleanPath
      revealProgress = 1
      return
    }

    oldBackground = cleanFrom || displayedBackground
    incomingBackground = cleanPath
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    var colorsIn = (typeof colorsB64 === "string") ? colorsB64 : ""
    var shellIn = (typeof shellB64 === "string") ? shellB64 : ""
    // Cap the encoded size before decoding to bound the decoded string too.
    // Base64 is ~4/3 the size of the raw payload; 4 * ceil(N/3) covers rounding.
    var maxEncoded = 4 * (Math.floor(maxThemePayloadBytes / 3) + 1)
    if (colorsIn.length > maxEncoded || shellIn.length > maxEncoded) {
      console.warn("spanned-background: theme payload rejected (over " + maxThemePayloadBytes + " bytes)")
      return
    }
    var colors = Util.decodeBase64(colorsIn)
    var shell = Util.decodeBase64(shellIn)
    if ((typeof colors === "string" && colors.length > maxThemePayloadBytes) ||
        (typeof shell === "string" && shell.length > maxThemePayloadBytes)) {
      console.warn("spanned-background: theme payload rejected after decode")
      return
    }
    pendingColorsRaw = colors
    pendingShellRaw = shell
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Color.loadColors(pendingColorsRaw)
    Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  // The wipe is driven globally, so the very first screen whose incoming frame
  // is decoded starts it and every other screen animates off the same clock.
  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  // owe draws a separate copy of a video on each output, so while spanning the
  // video is drawn again on top of owe's. The stills stay up until the first
  // spanned frame, and the shell's cover with them, so owe's per-monitor
  // picture never shows. If that frame does not arrive, owe's copy is what
  // the handover timer falls back to.
  function setOweActive(active) {
    oweActive = active
    if (!active) {
      videoHandoverTimer.stop()
      // The stills map again, which is not a theme cover.
      if (videoLoader.item) videoLoader.item.ignoreLayersUntil = Date.now() + 200
      suspended = false
      videoReleaseTimer.tries = 0
      videoReleaseTimer.restart()
      return
    }
    videoReleaseTimer.stop()
    if (!canSpanVideo) {
      stopHolding()
      videoPath = ""
      suspended = true
      return
    }
    videoLoader.item.cancelDismiss()
    holding = true
    if (!suspended) videoHandoverTimer.restart()
    queryVideo()
  }

  function finishVideo() {
    videoPath = ""
    videoRefused = ""
    stopHolding()
  }

  function stopHolding() {
    videoHoldTimer.stop()
    holding = false
    if (!isVideo(displayedBackground)) heldStill = displayedBackground
  }

  // The shell puts up a cover of the old wallpaper for a theme intro, cropped
  // to each monitor rather than to the canvas, and it maps above everything
  // already on its layer. So the video layer moves on top of it, holding the
  // spanned still, and the cover never shows. The hold ends by itself if
  // no video follows.
  function holdOverCover() {
    if (!canSpanVideo) return
    videoReleaseTimer.stop()
    videoLoader.item.cancelDismiss()
    videoLoader.item.raise()
    holding = true
    coverPending = true
    videoHoldTimer.restart()
  }

  function queryVideo() {
    if (!videoProc.running) {
      videoProc.buffer = ""
      videoProc.overflow = false
      videoProc.running = true
    }
  }

  function applyVideoState(payload) {
    if (payload === "locked") {
      if (videoLoop) videoPaused = true
      return
    }
    var probing = videoProbe
    videoProbe = false
    var fields = String(payload || "").split("\t")
    if (fields.length !== 3) return
    var path = normalisePath(fields[2])
    if (!path || !isVideo(path) || path === videoRefused) return
    if (!canSpanVideo) return
    // A shell restart or a login can miss owe's setSuspended call. Only the
    // probe at startup may conclude that: any later reply can be a stale one
    // that lands after owe handed the desktop back.
    if (!oweActive) {
      if (!probing) return
      oweActive = true
      videoHandoverTimer.restart()
    }
    var intro = fields[0] === "1"
    videoLoop = !intro
    videoPaused = !intro && fields[1] === "1"
    if (path === videoPath) return
    if (videoPath) videoLoader.item.swapTo(path)
    else videoPath = path
  }

  function applySpan(enabled, persist) {
    var next = !!enabled
    if (next !== spanEnabled) spanEnabled = next
    // Debounced rather than fired directly: two toggles in quick succession
    // must leave the file holding the *last* value, not the first.
    if (persist) spanPersistTimer.restart()
  }

  function openSelector() {
    if (!pickBgProc.running) pickBgProc.running = true
  }

  function openThemeSwitcher() {
    if (!pickThemeProc.running) pickThemeProc.running = true
  }

  // ---------------------------------------------------------------------
  // Every child process routes through a bundled bash helper in ./bin, each
  // invoked by absolute path. The helpers cap their own output at the
  // producer and refuse to touch symlinks or FIFOs on the file paths they
  // read and write. The two picker helpers, the only ones that start
  // long-running children, run them under `timeout -k`, which puts them in
  // their own process group and forwards a TERM to that whole group; the
  // helper forwards its own TERM to `timeout`. So `Process.signal(15)`, which
  // reaches only the helper, still tears down the picker's subtree. The
  // per-Process pieces below add QML-side deadlines and Component.onDestruction
  // teardown on top of that.
  //
  // The three file helpers only need HOME, so they run with a cleared
  // environment: nothing like BASH_ENV or a prepended PATH rides in.
  // ---------------------------------------------------------------------

  Process {
    id: pickBgProc
    command: [root.helperBin + "/pick-bg"]
    // The picker draws its own UI, so inheriting DISPLAY / WAYLAND_DISPLAY /
    // DBUS_SESSION_BUS_ADDRESS is required. The helper resets PATH before it
    // resolves omarchy-theme-bg-switcher / -bg-set.
    onExited: {
      pickBgWatchdog.stop()
      root.refreshBackground()
    }
    onRunningChanged: {
      if (running) pickBgWatchdog.restart()
      else pickBgWatchdog.stop()
    }
  }

  Process {
    id: pickThemeProc
    command: [root.helperBin + "/pick-theme"]
    onExited: {
      pickThemeWatchdog.stop()
      root.refreshBackground()
    }
    onRunningChanged: {
      if (running) pickThemeWatchdog.restart()
      else pickThemeWatchdog.stop()
    }
  }

  Process {
    id: resolveBgProc
    command: [root.helperBin + "/resolve-bg"]
    clearEnvironment: true
    environment: ({ "HOME": root.home, "PATH": "/usr/bin" })

    // The helper caps its own output at 4096 bytes and prints nothing on
    // rejection, but we still count bytes per chunk here so a helper somehow
    // induced to emit more (a bug in the helper, a filesystem oddity) can
    // never balloon the shell process. SplitParser with an empty split marker
    // hands raw chunks straight to onRead; we cap at the byte level and abort
    // the process on overflow instead of buffering.
    property string buffer: ""
    property bool overflow: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (resolveBgProc.overflow) return
        if (resolveBgProc.buffer.length + chunk.length > root.maxPathBytes) {
          resolveBgProc.overflow = true
          resolveBgProc.buffer = ""
          resolveBgProc.signal(15)
          resolveBgKillTimer.restart()
          return
        }
        resolveBgProc.buffer += chunk
      }
    }
    onExited: {
      resolveBgWatchdog.stop()
      resolveBgKillTimer.stop()
      var payload = resolveBgProc.buffer
      resolveBgProc.buffer = ""
      if (resolveBgProc.overflow) {
        resolveBgProc.overflow = false
        return
      }
      root.setBackground(payload, false)
    }
    onRunningChanged: {
      if (running) resolveBgWatchdog.restart()
      else resolveBgWatchdog.stop()
    }
  }

  Process {
    id: videoProc
    command: [root.helperBin + "/owe-video"]
    clearEnvironment: true
    environment: ({
      "HOME": root.home,
      "PATH": "/usr/bin",
      "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR"),
      "HYPRLAND_INSTANCE_SIGNATURE": Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    })

    property string buffer: ""
    property bool overflow: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (videoProc.overflow) return
        if (videoProc.buffer.length + chunk.length > root.maxPathBytes + 8) {
          videoProc.overflow = true
          videoProc.buffer = ""
          videoProc.signal(15)
          videoKillTimer.restart()
          return
        }
        videoProc.buffer += chunk
      }
    }
    onExited: {
      videoWatchdog.stop()
      videoKillTimer.stop()
      var payload = videoProc.buffer
      videoProc.buffer = ""
      if (videoProc.overflow) {
        videoProc.overflow = false
        return
      }
      root.applyVideoState(payload)
    }
    onRunningChanged: {
      if (running) videoWatchdog.restart()
      else videoWatchdog.stop()
    }
  }

  Process {
    id: spanReadProc
    command: [root.helperBin + "/read-conf"]
    clearEnvironment: true
    environment: ({ "HOME": root.home, "PATH": "/usr/bin" })

    property string buffer: ""
    property bool overflow: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (spanReadProc.overflow) return
        if (spanReadProc.buffer.length + chunk.length > 128) {
          spanReadProc.overflow = true
          spanReadProc.buffer = ""
          spanReadProc.signal(15)
          spanReadKillTimer.restart()
          return
        }
        spanReadProc.buffer += chunk
      }
    }
    onExited: {
      spanReadWatchdog.stop()
      spanReadKillTimer.stop()
      var v = spanReadProc.buffer.replace(/[\r\n\t ]+/g, "").toLowerCase()
      spanReadProc.buffer = ""
      if (spanReadProc.overflow) {
        spanReadProc.overflow = false
        return
      }
      if (v === "off") root.applySpan(false, false)
      else if (v === "on") root.applySpan(true, false)
    }
    onRunningChanged: {
      if (running) spanReadWatchdog.restart()
      else spanReadWatchdog.stop()
    }
  }

  Process {
    id: spanWriteProc
    // Argv-only: the on/off value is a separate element, not spliced into a
    // shell string, and the helper validates it against a closed allowlist
    // before it touches the filesystem.
    command: [root.helperBin + "/write-conf", root.spanEnabled ? "on" : "off"]
    clearEnvironment: true
    environment: ({ "HOME": root.home, "PATH": "/usr/bin" })
    onExited: spanWriteWatchdog.stop()
    onRunningChanged: {
      if (running) spanWriteWatchdog.restart()
      else spanWriteWatchdog.stop()
    }
  }

  // Watchdogs: each Process has an outer QML deadline that TERM/KILL-escalates
  // the wrapper if the in-helper `timeout` somehow fails to fire. A TERM to a
  // picker helper is forwarded to its `timeout`, which unwinds the subtree.
  Timer { id: pickBgWatchdog;      interval: 630000; repeat: false; onTriggered: if (pickBgProc.running)    { pickBgProc.signal(15);    pickBgKillTimer.restart() } }
  Timer { id: pickBgKillTimer;     interval: 2000;  repeat: false; onTriggered: if (pickBgProc.running)    pickBgProc.signal(9) }
  Timer { id: pickThemeWatchdog;   interval: 630000; repeat: false; onTriggered: if (pickThemeProc.running) { pickThemeProc.signal(15); pickThemeKillTimer.restart() } }
  Timer { id: pickThemeKillTimer;  interval: 2000;  repeat: false; onTriggered: if (pickThemeProc.running) pickThemeProc.signal(9) }
  Timer { id: resolveBgWatchdog;   interval: 10000; repeat: false; onTriggered: if (resolveBgProc.running) { resolveBgProc.signal(15); resolveBgKillTimer.restart() } }
  Timer { id: resolveBgKillTimer;  interval: 2000;  repeat: false; onTriggered: if (resolveBgProc.running) resolveBgProc.signal(9) }
  Timer { id: spanReadWatchdog;    interval: 5000;  repeat: false; onTriggered: if (spanReadProc.running)  { spanReadProc.signal(15);  spanReadKillTimer.restart() } }
  Timer { id: spanReadKillTimer;   interval: 2000;  repeat: false; onTriggered: if (spanReadProc.running)  spanReadProc.signal(9) }
  Timer { id: spanWriteWatchdog;   interval: 5000;  repeat: false; onTriggered: if (spanWriteProc.running) { spanWriteProc.signal(15); spanWriteKillTimer.restart() } }
  Timer { id: spanWriteKillTimer;  interval: 2000;  repeat: false; onTriggered: if (spanWriteProc.running) spanWriteProc.signal(9) }
  Timer { id: videoWatchdog;       interval: 6000;  repeat: false; onTriggered: if (videoProc.running)     { videoProc.signal(15);     videoKillTimer.restart() } }
  Timer { id: videoKillTimer;      interval: 2000;  repeat: false; onTriggered: if (videoProc.running)     videoProc.signal(9) }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    // owe calls this to hand the desktop over and back. Without it the call
    // fails and owe falls back to setPluginEnabled, which turns the built-in
    // omarchy.background on again in shell.json, on top of this plugin.
    function setSuspended(value: string): void {
      root.setOweActive(value === "true")
    }

    // A theme switch names its next background early so stock can decode it
    // ahead of the transition. Accepted so the call succeeds; nothing to do.
    function prepare(path: string): void {
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }

    // Extra: omarchy-shell -q background span on|off|toggle
    // Anything else is refused rather than guessed at -- a mistyped "on" must
    // not silently turn spanning off.
    function span(mode: string): void {
      var raw = (typeof mode === "string") ? mode : ""
      if (raw.length > 32) {
        console.warn("spanned-background: span mode too long")
        return
      }
      var m = raw.replace(/[\r\n\t ]+/g, "").toLowerCase()
      if (m === "on" || m === "true" || m === "1") root.applySpan(true, true)
      else if (m === "off" || m === "false" || m === "0") root.applySpan(false, true)
      else if (m === "toggle" || m === "") root.applySpan(!root.spanEnabled, true)
      else console.warn("spanned-background: unknown span mode (expected on, off or toggle)")
    }
  }

  // Writes the current value once things have settled; if a write is somehow
  // still in flight, wait and try again rather than dropping it.
  Timer {
    id: spanPersistTimer
    interval: 200
    repeat: false
    onTriggered: {
      if (spanWriteProc.running) spanPersistTimer.restart()
      else spanWriteProc.running = true
    }
  }

  // Follows owe while it has the desktop: a new video, and its pause state.
  Timer {
    interval: root.videoPath ? 1000 : 250
    repeat: true
    running: root.oweActive && root.canSpanVideo
    onTriggered: root.queryVideo()
  }

  Timer {
    id: videoHandoverTimer
    interval: 1500
    repeat: false
    onTriggered: {
      console.warn("spanned-background: no spanned frame in time, leaving the video to owe")
      root.suspended = true
      root.stopHolding()
    }
  }

  Timer {
    id: videoHoldTimer
    interval: 4000
    repeat: false
    onTriggered: {
      root.coverPending = false
      if (!root.videoPath) root.stopHolding()
      else if (!root.oweActive) {
        videoReleaseTimer.tries = 0
        videoReleaseTimer.restart()
      }
    }
  }

  // The video's last frame stays up until the still under it has loaded.
  Timer {
    id: videoReleaseTimer
    interval: 400
    repeat: true
    property int tries: 0
    onTriggered: {
      tries += 1
      if (root.oweActive || root.coverPending) stop()
      else if (root.ready || tries >= 8) {
        stop()
        if (videoLoader.item) videoLoader.item.dismiss()
        else root.finishVideo()
      }
    }
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  // Recompute right away so a hotplug never leaves a frame drawn against the
  // old bounding box, then again once the layout has stopped moving -- a single
  // reshuffle can report several intermediate positions before it settles.
  Timer {
    id: geometryTimer
    interval: 120
    repeat: false
    onTriggered: root.recomputeGeometry()
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.scheduleGeometryUpdate()
    }
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incomingBackground) {
        root.displayedBackground = root.currentBackground && !root.isVideo(root.currentBackground)
          ? root.currentBackground : root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: {
    recomputeGeometry()
    spanReadProc.running = true
    refreshBackground()
    queryVideo()
  }

  // Tear down every helper we spawned when this service is torn down. Sends
  // SIGTERM to the wrapper; the picker helpers forward it to `timeout`, which
  // signals the picker's whole process group.
  Component.onDestruction: {
    var procs = [pickBgProc, pickThemeProc, resolveBgProc, spanReadProc, spanWriteProc, videoProc]
    for (var i = 0; i < procs.length; i++) {
      if (procs[i].running) procs[i].signal(15)
    }
  }

  Loader {
    id: videoLoader
    active: root.spanning && Quickshell.screens.length > 1
    source: "VideoSpan.qml"
    onLoaded: item.host = root
  }

  Connections {
    target: videoLoader.item
    function onStarted() {
      videoHandoverTimer.stop()
      videoHoldTimer.stop()
      root.coverPending = false
      root.suspended = true
    }
    function onCoverOpened() {
      root.holdOverCover()
    }
    function onDismissed() {
      root.finishVideo()
    }
    function onFailed(path) {
      console.warn("spanned-background: video will not span, leaving it to owe")
      root.videoRefused = path
      root.videoPath = ""
      root.coverPending = false
      root.stopHolding()
      videoHandoverTimer.stop()
      root.suspended = true
    }
  }

  Variants {
    id: backgrounds
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      readonly property bool backgroundReady: base.status === Image.Ready

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      visible: !remapGuard.remapping && !root.suspended
      color: "transparent"

      // Kept from the stock plugin: a background surface that stops receiving
      // updates has been observed to lose its committed buffer, leaving a black
      // desktop until omarchy-shell is restarted.
      updatesEnabled: true

      // Hyprland leaves an already-mapped layer surface at its old global
      // position when its monitor moves within the layout, so the surface has
      // to be unmapped and remapped. Undocking, replugging and `hyprctl reload`
      // all hit this, and this plugin makes those events load-bearing.
      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      property bool maskReady: false

      // Mirrors of this output's geometry. ShellScreen emits xChanged/yChanged
      // and friends, so these fire on layout changes and are what recompute the
      // shared bounding box.
      readonly property real screenX: modelData && root.isNum(modelData.x) ? modelData.x : 0
      readonly property real screenY: modelData && root.isNum(modelData.y) ? modelData.y : 0
      readonly property real screenW: modelData && root.isNum(modelData.width) ? modelData.width : 0
      readonly property real screenH: modelData && root.isNum(modelData.height) ? modelData.height : 0

      onScreenXChanged: root.scheduleGeometryUpdate()
      onScreenYChanged: root.scheduleGeometryUpdate()
      onScreenWChanged: root.scheduleGeometryUpdate()
      onScreenHChanged: root.scheduleGeometryUpdate()

      // Where the shared canvas sits relative to this output. With spanning off
      // these collapse onto the content item, which is stock `anchors.fill`
      // behaviour. They deliberately track `stage` rather than the window: with
      // opposite anchors set, PanelWindow ignores width/height as inputs and
      // reading them back can hand you a stale zero.
      readonly property real canvasX: root.spanning ? -(screenX - root.virtualX) : 0
      readonly property real canvasY: root.spanning ? -(screenY - root.virtualY) : 0
      readonly property real canvasW: root.spanning ? root.virtualWidth : stage.width
      readonly property real canvasH: root.spanning ? root.virtualHeight : stage.height

      // Deliberately does NOT require the wipe to be sitting at zero. Each
      // panel decodes the incoming image independently, so on a multi-monitor
      // setup the second screen almost always becomes ready after the animation
      // has started; gating on that would leave it masked out for the whole
      // transition and then hard-cut. Joining a wipe in progress is the point.
      function maybeStartReveal() {
        if (!root.incomingBackground || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || panel.maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      // Clipped to the output, so each screen only ever rasterises its own slice
      // of the canvas. Every panel asks for the same image at the same size, so
      // Qt's pixmap cache keeps one decode between them, exactly as in stock.
      Item {
        id: stage
        anchors.fill: parent
        clip: true

        Image {
          id: base
          x: panel.canvasX
          y: panel.canvasY
          width: panel.canvasW
          height: panel.canvasH
          source: root.imageUrl(root.displayedBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          onStatusChanged: {
            if (status === Image.Ready && root.finishingTransition) {
              root.incomingBackground = ""
              root.oldBackground = ""
              root.finishingTransition = false
            }
          }
        }

        Image {
          id: oldFrame
          x: panel.canvasX
          y: panel.canvasY
          width: panel.canvasW
          height: panel.canvasH
          source: root.imageUrl(root.oldBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          visible: root.oldBackground !== "" && root.revealProgress < 1
          onStatusChanged: panel.maybeStartReveal()
        }

        Item {
          id: incomingLayer
          anchors.fill: parent
          visible: root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady)
          layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
          layer.smooth: true
          layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: revealMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 0.02
          }

          Image {
            id: incomingFrame
            x: panel.canvasX
            y: panel.canvasY
            width: panel.canvasW
            height: panel.canvasH
            source: root.imageUrl(root.incomingBackground)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            smooth: true
            mipmap: true
            onStatusChanged: panel.maybeStartReveal()
          }
        }

        // The wipe is described in canvas coordinates and then shifted into this
        // output's local space, so one diagonal sweeps continuously across every
        // monitor instead of each screen wiping on its own.
        Item {
          id: revealMask
          anchors.fill: parent
          visible: false
          layer.enabled: true

          readonly property real slant: root.revealSlant
          readonly property real cw: panel.canvasW
          readonly property real ch: panel.canvasH
          readonly property real centerTop: cw / 2 - slant * ch / 2
          readonly property real centerBottom: cw / 2 + slant * ch / 2
          readonly property real reach: cw / 2 + Math.abs(slant) * ch / 2 + 4
          readonly property real spread: reach * root.revealProgress
          readonly property real ox: panel.canvasX
          readonly property real oy: panel.canvasY

          Shape {
            anchors.fill: parent
            antialiasing: true
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              fillColor: "white"
              strokeColor: "transparent"
              startX: revealMask.ox + revealMask.centerTop - revealMask.spread
              startY: revealMask.oy
              PathLine { x: revealMask.ox + revealMask.centerTop + revealMask.spread; y: revealMask.oy }
              PathLine { x: revealMask.ox + revealMask.centerBottom + revealMask.spread; y: revealMask.oy + revealMask.ch }
              PathLine { x: revealMask.ox + revealMask.centerBottom - revealMask.spread; y: revealMask.oy + revealMask.ch }
              PathLine { x: revealMask.ox + revealMask.centerTop - revealMask.spread; y: revealMask.oy }
            }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
