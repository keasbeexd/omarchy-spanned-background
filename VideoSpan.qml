import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import QtMultimedia
import qs.Ui

// Plays one video across every monitor, on top of owe's own layer.
//
// owe draws a separate copy of a video on each output and has no way to crop
// it, so a spanned video has to be drawn here. QML cannot hand one player's
// frames to a second window, so each screen gets its own player, showing its
// slice of the same canvas the stills use. They hold at the loaded state until
// every one is ready and then start together.
//
// Each window also carries the still the video is replacing, so the video can
// fade in over it within the canvas, and so this layer can stand in for the
// desktop while the shell's per-monitor theme cover is up beneath it.
//
// The shell's cover maps above everything already on the Bottom layer, and it
// only appears for about a second, so there is no time for a map of our own.
// These windows therefore stay mapped and built, empty, on the Background
// layer. Moving a mapped surface to another layer puts it on top of that layer
// in one commit, with no configure round trip and nothing to construct.
//
// This file stays apart from SpannedBackground.qml so that a system without
// QtMultimedia fails this Loader alone and keeps owe's per-monitor video.
Item {
  id: span

  property var host: null
  readonly property string path: host ? host.videoPath : ""
  readonly property url source: path ? fileUrl(path) : ""
  readonly property bool holding: host ? host.holding : false
  // Every screen has a frame up.
  property bool live: false
  // On the Bottom layer, above owe and the shell's cover.
  readonly property bool raised: (holding || live) && !lowered
  property bool lowered: false
  property bool playing: false
  // One video is replacing another: its last frame stays up as a freeze.
  property bool frozen: false
  property real contentOpacity: 1
  property string nextPath: ""
  // The cover maps once per screen, and this layer has to land above them all.
  property int coversSeen: 0
  // These windows mapping when the plugin loads is not a cover.
  property real ignoreLayersUntil: Date.now() + 1500
  property var loadedScreens: ({})
  property var framedScreens: ({})
  // Eases in gently: the first video frame stalls the renderer for a moment,
  // and an ease that moves early would lose its start to that stall.
  readonly property int fadeMs: 640

  // The first spanned frame is on every screen.
  signal started()
  // A screen could not play the file; owe keeps showing it.
  signal failed(string path)
  // Something else mapped on this layer's namespace: the shell's theme cover.
  signal coverOpened()
  signal freezeRequested()
  // The layer has faded out and can let go of the video.
  signal dismissed()

  function fileUrl(p) {
    return host ? host.mediaUrl(p) : ""
  }

  function count(map) {
    return Object.keys(map).length
  }

  function markLoaded(name) {
    loadedScreens[name] = true
    if (count(loadedScreens) >= panels.instances.length) playing = true
  }

  function markFramed(name) {
    framedScreens[name] = true
    if (count(framedScreens) >= panels.instances.length) {
      live = true
      started()
    }
  }

  // A wallpaper that changed behind this layer would otherwise appear as a cut.
  function dismiss() {
    dismissFade.restart()
  }

  function cancelDismiss() {
    dismissFade.stop()
    contentOpacity = 1
  }

  // The freeze is taken from the output, so it has to be drawn before the
  // player lets go of the old video.
  function swapTo(next) {
    nextPath = next
    if (swapTimer.running) return
    frozen = true
    freezeRequested()
    swapTimer.restart()
  }

  // Already raised means something newer landed on top, so go down and back.
  function raise() {
    if (raised) {
      lowered = true
      remapTimer.restart()
    }
  }

  onPathChanged: {
    playing = false
    loadedScreens = ({})
    framedScreens = ({})
    live = false
    if (path === "") frozen = false
  }

  NumberAnimation {
    id: dismissFade
    target: span
    property: "contentOpacity"
    from: 1
    to: 0
    duration: span.fadeMs / 2
    easing.type: Easing.InOutCubic
    onFinished: {
      span.dismissed()
      span.contentOpacity = 1
    }
  }

  Timer {
    id: swapTimer
    interval: 34
    repeat: false
    onTriggered: span.host.videoPath = span.nextPath
  }

  Timer {
    id: remapTimer
    interval: 16
    repeat: false
    onTriggered: span.lowered = false
  }

  // A cover that never reaches every screen still has to be answered.
  Timer {
    id: coverTimer
    interval: 30
    repeat: false
    onTriggered: {
      span.coversSeen = 0
      span.coverOpened()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "openlayer" || event.data !== "omarchy-background") return
      if (Date.now() < span.ignoreLayersUntil) return
      span.coversSeen += 1
      if (span.coversSeen >= panels.instances.length) {
        coverTimer.stop()
        span.coversSeen = 0
        span.coverOpened()
      } else {
        coverTimer.restart()
      }
    }
  }

  Variants {
    id: panels
    model: span.host ? Quickshell.screens : []

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      visible: !remapGuard.remapping
      color: "transparent"
      // Clicks reach whatever is below, as they would without this layer.
      mask: Region {}

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: span.raised ? WlrLayer.Bottom : WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Item {
        id: stage
        anchors.fill: parent
        clip: true
        opacity: span.contentOpacity

        property bool framed: false
        // Changing source reports Loaded for the outgoing file first, so that
        // state means nothing until this file has been seen to start loading.
        property bool sawLoading: false
        readonly property bool shouldPlay: span.playing && !span.host.videoPaused

        onShouldPlayChanged: {
          if (shouldPlay) player.play()
          else player.pause()
        }

        // A monitor connected during a video arrives with shouldPlay and live
        // already true, so nothing that reacts to them would start its player
        // or show its output.
        Component.onCompleted: {
          if (shouldPlay) player.play()
          if (span.live) output.opacity = 1
        }

        Item {
          id: canvas
          x: span.host.spanning ? span.host.virtualX - panel.modelData.x : 0
          y: span.host.spanning ? span.host.virtualY - panel.modelData.y : 0
          width: span.host.spanning ? span.host.virtualWidth : stage.width
          height: span.host.spanning ? span.host.virtualHeight : stage.height

          // Shares the desktop's decoded image through Qt's pixmap cache, and
          // keeps it after a theme switch deletes the file.
          Image {
            anchors.fill: parent
            source: span.host.heldStill ? span.host.imageUrl(span.host.heldStill) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            // Hidden items hold no texture, and uploading one this size stalls
            // the first frame by long enough to show the cover. It is the same
            // image as the desktop below, so this faint copy cannot be seen.
            opacity: span.holding ? 1 : 0.01
          }

          // Taken once, under the output, so a new video fades in over the
          // old one's last frame rather than cutting to it.
          ShaderEffectSource {
            id: freeze
            anchors.fill: parent
            sourceItem: output
            live: false
            visible: span.frozen
          }

          VideoOutput {
            id: output
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectCrop
            endOfStreamPolicy: VideoOutput.KeepLastFrame
            opacity: 0
          }

          Connections {
            target: span
            function onFreezeRequested() {
              freeze.scheduleUpdate()
            }
            function onLiveChanged() {
              if (span.live) {
                fade.restart()
              } else {
                fade.stop()
                output.opacity = 0
              }
            }
          }

          NumberAnimation {
            id: fade
            target: output
            property: "opacity"
            from: 0
            to: 1
            duration: span.fadeMs
            easing.type: Easing.InOutCubic
            onFinished: span.frozen = false
          }
        }

        // No audioOutput, so a wallpaper stays silent.
        MediaPlayer {
          id: player
          source: span.source
          videoOutput: output
          loops: span.host.videoLoop ? MediaPlayer.Infinite : 1
          onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.LoadingMedia) {
              stage.sawLoading = true
            } else if (mediaStatus === MediaPlayer.LoadedMedia && stage.sawLoading) {
              stage.sawLoading = false
              span.markLoaded(panel.modelData.name)
            } else if (mediaStatus === MediaPlayer.InvalidMedia) {
              span.failed(span.path)
            }
          }
          onErrorOccurred: span.failed(span.path)
        }

        Connections {
          target: output.videoSink
          enabled: !stage.framed && span.path !== ""
          function onVideoFrameChanged() {
            // A source change passes through the sink too, before the new
            // file has anything to show.
            if (player.mediaStatus !== MediaPlayer.BufferedMedia) return
            stage.framed = true
            span.markFramed(panel.modelData.name)
          }
        }

        Connections {
          target: span
          function onPathChanged() {
            stage.framed = false
          }
        }
      }
    }
  }
}
