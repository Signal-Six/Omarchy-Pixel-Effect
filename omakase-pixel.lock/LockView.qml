// Omakase Pixel — lock screen
//
// Fork of the stock omarchy.lock view. The contract with Service.qml is
// UNCHANGED: same input properties, same output signals, same names. All
// authentication logic lives in Service.qml (kept byte-identical to stock).
//
// The only addition is the theme's shimmering PIXEL BORDER (the same
// value-noise edge band as the SDDM greeter, ported 1:1 — see
// Omarchy-Pixel-Effect/src/pixel-field.js), drawn as a Canvas over the
// blurred wallpaper and under the input field, dimmed ~45% so it reads
// as a frame over the wallpaper instead of a solid band.
//
// Palette: ~/.config/omarchy/themes/omakase-pixel/pixel_palette.toml
// No-motion opt-out: OMARCHY_PIXEL_WIPE=0 via the omarchy-launch-shell
// PATH shadow (same env var the menu pixel wipe uses).

import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false

  readonly property string placeholderText: "Enter Password"
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Commons.Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Commons.Color.lock.borderActive, root.outlineThickness, "border-alpha")

  // --- Omakase Pixel: shimmering edge band (palette: pixel_palette.toml) ---
  // Value-noise pixel border hugging the screen edge, identical math to the
  // SDDM greeter (extras/sddm/omakase-pixel/Main.qml) minus the opaque
  // background fill, so the band composites over the blurred wallpaper.
  // Declared on root (not a nested item) so the Canvas/QtObject reach them
  // through the `root` id.
  readonly property int pixelBandCells: 4
  readonly property real pixelCellSize: Math.max(9, Math.min(15, width / 170))
  readonly property bool pixelReduced: Quickshell.env("OMARCHY_PIXEL_WIPE") === "0"

  // 8x8 per-cell threshold hash (same values as the site)
  readonly property var pixelHash8: [0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24,
      50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30,
      54, 22, 3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
      15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21]

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  // Cache-busts the lock background by appending `?v=`. Adding a query
  // string keeps Image's loader happy while forcing it to reload when the
  // user picks a new background mid-session.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + backgroundVersion
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.loadBackground ? root.fileUrl(root.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && wallpaper.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    // --- Omakase Pixel: shimmering edge band -------------------------
    // Value-noise pixel border hugging the screen edge, identical math to
    // the SDDM greeter (extras/sddm/omakase-pixel/Main.qml) minus the
    // opaque background fill, so the blurred wallpaper still shows through.
    // (Configuration properties live on the root Item — see pixelBandCells.)

    QtObject {
      id: pxFx
      property var noise: null
      property var rnd: null
      property var cells: null
      property real cellsW: 0
      property real cellsH: 0

      function init() {
        var NOISE = 128
        // LCG with the web module's exact seeds -> identical noise field.
        var s = 10407530
        function lcg() { s = (s * 1664525 + 1013904223) % 4294967296; if (s < 0) s += 4294967296; return s / 4294967296 }
        var cur = new Array(NOISE * NOISE)
        for (var i = 0; i < cur.length; i++) cur[i] = lcg()
        for (var p = 0; p < 2; p++) {
          var out = new Array(NOISE * NOISE)
          for (var y = 0; y < NOISE; y++) {
            for (var x = 0; x < NOISE; x++) {
              var sum = 0
              for (var dy = -1; dy <= 1; dy++)
                for (var dx = -1; dx <= 1; dx++)
                  sum += cur[(((y + dy + NOISE) % NOISE) * NOISE) + (((x + dx + NOISE) % NOISE))]
              out[y * NOISE + x] = sum / 9
            }
          }
          cur = out
        }
        var lo = 1e9, hi = -1e9
        for (var j = 0; j < cur.length; j++) { if (cur[j] < lo) lo = cur[j]; if (cur[j] > hi) hi = cur[j] }
        var span = (hi - lo) || 1
        for (var k = 0; k < cur.length; k++) cur[k] = (cur[k] - lo) / span
        pxFx.noise = cur

        var s2 = 663316
        function lcg2() { s2 = (s2 * 1664525 + 1013904223) % 4294967296; if (s2 < 0) s2 += 4294967296; return s2 / 4294967296 }
        var r = new Array(4096)
        for (var m = 0; m < 4096; m++) r[m] = lcg2()
        pxFx.rnd = r
      }

      // Perimeter parameter (0..1) so the shimmer travels at constant speed
      // around the border instead of wobbling with the aspect ratio.
      function perim(u, v) {
        var du = u - 0.5, dv = v - 0.5
        var m = Math.max(Math.abs(du), Math.abs(dv))
        if (m < 1e-9) return 0
        var qu = du / m, qv = dv / m
        if (qv <= -1 + 1e-6 && Math.abs(qu) <= 1) return (qu + 1) / 8          // top
        if (qu >= 1 - 1e-6)                      return 0.25 + (qv + 1) / 8     // right
        if (qv >= 1 - 1e-6)                      return 0.50 + (1 - qu) / 8     // bottom
        return 0.75 + (1 - qv) / 8                                              // left
      }

      // Entry: [rx, ry, rw, rh, cx, cy, de, p, dcol, drow]
      function rebuild(w, h, S) {
        if (pxFx.cellsW === w && pxFx.cellsH === h) return
        pxFx.cellsW = w
        pxFx.cellsH = h
        var nc = Math.ceil(w / S)
        var nr = Math.ceil(h / S)
        var band = root.pixelBandCells
        var cells = []
        for (var tr = 0; tr < nr; tr++) {
          var deY = Math.min(tr, nr - 1 - tr)
          var ry = tr * S + 1      // 1px gap between cells (crisp look)
          for (var d = 0; d < nc; d++) {
            var deX = Math.min(d, nc - 1 - d)
            if (deX >= band && deY >= band) continue
            cells.push([d * S + 1, ry, S - 1, S - 1, d * S + S / 2, tr * S + S / 2,
                        Math.min(deX, deY),
                        perim((d + 0.5) / nc, (tr + 0.5) / nr), d, tr])
          }
        }
        pxFx.cells = cells
      }
    }

    Canvas {
      id: pxField
      anchors.fill: parent
      opacity: 0
      antialiasing: false
      visible: !root.pixelReduced

      function sample(u, v) {
        var NOISE = 128
        var iu = Math.floor(u), iv = Math.floor(v)
        var fu = u - iu, fv = v - iv
        var su = fu * fu * (3 - 2 * fu), sv = fv * fv * (3 - 2 * fv)
        var x0 = ((iu % NOISE) + NOISE) % NOISE, x1 = (x0 + 1) % NOISE
        var y0 = ((iv % NOISE) + NOISE) % NOISE, y1 = (y0 + 1) % NOISE
        var n = pxFx.noise
        var a = n[y0 * NOISE + x0], b = n[y0 * NOISE + x1]
        var c = n[y1 * NOISE + x0], d = n[y1 * NOISE + x1]
        return (a * (1 - su) + b * su) * (1 - sv) + (c * (1 - su) + d * su) * sv
      }

      function glowAt(px, py, gx, gy, strength, reach) {
        var dx = px - gx, dy = py - gy
        var dist = Math.sqrt(dx * dx + dy * dy)
        if (dist >= reach) return 0
        var f = 1 - dist / reach
        return f * f * strength
      }

      function shimmer(p, e) {
        var a = 0.5 + 0.5 * Math.sin(p * 6.283185307 * 5 - e * 2.6)
        var b = 0.5 + 0.5 * Math.sin(p * 6.283185307 * 1 - e * 0.9 + 1.7)
        return Math.pow(a, 8) + 0.55 * Math.pow(b, 10)
      }

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var w = width, h = height
        if (w < 50 || h < 50 || !pxFx.noise) return

        pxFx.rebuild(w, h, root.pixelCellSize)

        var e = Date.now() / 1000
        var S = root.pixelCellSize
        var rnd = pxFx.rnd
        var hash8 = root.pixelHash8

        // Unlike the greeter, there is NO opaque background fill here: the
        // band composites over the blurred wallpaper, and the interior
        // keeps showing it untouched so the password field stays legible.

        // wanderer: slow glow drifting through the band
        var nx = 0.44 * (1 + 0.1 * Math.sin(e * 0.11))
        var ny = 0.38 * (1 + 0.1 * Math.sin(e * 0.09 + 2))
        var wx = w * (0.5 + nx * Math.sin(e * 0.65))
        var wy = h * (0.48 + ny * Math.sin(e * 0.39 + 1.1))
        var wreach = 12 * S * (0.45 + 0.55 * 0.7)

        // Dimmed ~45% vs the greeter — it frames the wallpaper instead of
        // replacing it.
        ctx.globalAlpha = 0.55

        var dimB = [], midB = [], litB = [], crestB = []
        var cells = pxFx.cells
        for (var i = 0; i < cells.length; i++) {
          var c = cells[i]
          var d = c[8], tr = c[9]
          var de = c[6]

          var n1 = 0.6 * sample(d / 9 + e * 0.14, tr / 9 - e * 0.055)
                 + 0.4 * sample(d * 0.55 - e * 0.08, tr * 0.55 + e * 0.06)
          var twinkle = 0.5 + 0.5 * Math.sin(e * 1.1 + rnd[(tr * 37 + d * 11) & 4095] * 6.283)
          var b = 0.78 * n1 + 0.22 * twinkle
          var density = Math.pow(0.6, de) * (0.6 + 0.5 * b)
          var u = 0.78 * (hash8[(tr & 7) * 8 + (d & 7)] + 0.5) / 64
                + 0.22 * rnd[(tr & 63) * 64 + (d & 63)]
          if (u >= density) continue

          var sh = shimmer(c[7], e) * (0.45 + 0.55 / (1 + de))
          var v = glowAt(c[4], c[5], wx, wy, 0.7, wreach)
          var bright = 0.34 * b + 0.72 * Math.min(1, sh) + 0.6 * v

          if (bright >= 0.72) crestB.push(c)
          else if (bright >= 0.42) litB.push(c)
          else if (bright >= 0.18) midB.push(c)
          else dimB.push(c)
        }
        ctx.fillStyle = "#374e57"   // dim
        for (i = 0; i < dimB.length; i++) ctx.fillRect(dimB[i][0], dimB[i][1], dimB[i][2], dimB[i][3])
        ctx.fillStyle = "#4e7381"   // mid
        for (i = 0; i < midB.length; i++) ctx.fillRect(midB[i][0], midB[i][1], midB[i][2], midB[i][3])
        ctx.fillStyle = "#6fa7bb"   // lit
        for (i = 0; i < litB.length; i++) ctx.fillRect(litB[i][0], litB[i][1], litB[i][2], litB[i][3])
        ctx.fillStyle = "#dce1e7"   // crest
        for (i = 0; i < crestB.length; i++) ctx.fillRect(crestB[i][0], crestB[i][1], crestB[i][2], crestB[i][3])
      }
    }

    Timer {
      interval: 25          // ~40 fps, same cap as the web module
      running: !root.pixelReduced
      repeat: true
      onTriggered: pxField.requestPaint()
    }

    // One-shot fade-in (matches the site's px-field-warmup)
    NumberAnimation {
      id: pxFade
      target: pxField
      property: "opacity"
      from: 0
      to: 1
      duration: 900
      easing.type: Easing.OutCubic
      running: false
    }

    Component.onCompleted: {
      if (!root.pixelReduced) {
        pxFx.init()
        pxFade.start()
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    BorderSurface {
      id: inputField
      width: root.fieldWidth
      height: root.fieldHeight
      anchors.centerIn: parent
      color: Commons.Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "\u25CF"
        passwordMaskDelay: 0
        color: Commons.Color.lock.text
        selectionColor: Commons.Color.lock.selection
        selectedTextColor: Commons.Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Commons.Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          root.passwordTextEdited("")
          if (submitted.length > 0) root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? "Checking…" : (root.failureMessage.length > 0 ? root.failureMessage : root.placeholderText)
        visible: passwordInput.text.length === 0
        color: root.authenticatingPassword ? Commons.Color.lock.text : (root.failureMessage.length > 0 ? Commons.Color.lock.textError : Commons.Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      // Matches hyprlock, which draws its fingerprint icon in the same spot.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        color: Commons.Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
