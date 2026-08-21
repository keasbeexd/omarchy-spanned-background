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
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

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

  // Bounding box of every output, in compositor logical coordinates. Because
  // Hyprland lays every monitor out in one logical coordinate space, this works
  // for mixed resolutions, mixed scale factors and rotated panels alike.
  property real virtualX: 0
  property real virtualY: 0
  property real virtualWidth: 0
  property real virtualHeight: 0
  property bool geometryValid: false

  readonly property bool spanning: spanEnabled && geometryValid

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function isNum(v) {
    return typeof v === "number" && isFinite(v)
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
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function setBackground(path, instant) {
    transitionBackground("", path, path, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    currentBackground = finalPath
    backgroundVersion += 1
    revealStartedVersion = -1

    revealAnimation.stop()
    finishingTransition = false

    if (instant || !displayedBackground) {
      oldBackground = ""
      incomingBackground = ""
      displayedBackground = path
      revealProgress = 1
      return
    }

    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
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

  function applySpan(enabled, persist) {
    var next = !!enabled
    if (next !== spanEnabled) spanEnabled = next
    // Debounced rather than fired directly: two toggles in quick succession
    // must leave the file holding the *last* value, not the first.
    if (persist) spanPersistTimer.restart()
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  Process {
    id: spanReadProc
    command: ["bash", "-c", "grep -m1 '^span=' \"$HOME/.config/omarchy/spanned-background.conf\" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]'"]
    stdout: StdioCollector {
      onStreamFinished: {
        var v = String(text || "").trim().toLowerCase()
        if (v === "off" || v === "false" || v === "0" || v === "no") root.applySpan(false, false)
        else if (v === "on" || v === "true" || v === "1" || v === "yes") root.applySpan(true, false)
      }
    }
  }

  Process {
    id: spanWriteProc
    command: ["bash", "-c", "mkdir -p \"$HOME/.config/omarchy\" && printf 'span=%s\\n' \"$1\" > \"$HOME/.config/omarchy/spanned-background.conf\"", "spanned-background", root.spanEnabled ? "on" : "off"]
  }

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
      var m = String(mode || "").trim().toLowerCase()
      if (m === "on" || m === "true" || m === "1") root.applySpan(true, true)
      else if (m === "off" || m === "false" || m === "0") root.applySpan(false, true)
      else if (m === "toggle" || m === "") root.applySpan(!root.spanEnabled, true)
      else console.warn("spanned-background: unknown span mode '" + mode + "' (expected on, off or toggle)")
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
        root.displayedBackground = root.currentBackground || root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: {
    recomputeGeometry()
    spanReadProc.running = true
    refreshBackground()
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      visible: !remapGuard.remapping
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
