import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// Loads hypr/appcolor.lua into Hyprland's Lua, so nobody has to edit
// hyprland.lua. A Hyprland config reload starts Lua afresh, so the module is
// loaded again after each one; a reload is also how a new Omarchy theme
// lands, and colours taken from the theme are then derived again.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string dir: {
    var url = String(Qt.resolvedUrl("."))
    var path = decodeURIComponent(url.replace(/^file:\/\//, ""))
    return path.replace(/\/+$/, "")
  }
  readonly property string bin: dir + "/bin/appcolor"
  // The folder goes into a Lua string and a shell command; refuse anything
  // that could end either early.
  readonly property bool dirSafe: dir.length > 0 && !/['"\\\n\r]/.test(dir)

  property string lastThemeColors: ""

  function loadModule() {
    if (!dirSafe) {
      console.warn("[appcolor] plugin folder has quotes or backslashes in its path; not loading: " + dir)
      return
    }
    Quickshell.execDetached(["hyprctl", "eval",
      "AppColorDir = '" + dir + "'; dofile('" + dir + "/hypr/appcolor.lua')"])
  }

  function checkTheme() {
    var colors = themeColors.text()
    if (lastThemeColors !== "" && colors !== lastThemeColors)
      Quickshell.execDetached([bin, "rebuild"])
    lastThemeColors = colors
  }

  FileView {
    id: themeColors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    blockLoading: true
    printErrors: false
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && String(event.name) === "configreloaded") {
        reloadDelay.restart()
      }
    }
  }

  // Let the reload settle before loading into the new Lua.
  Timer {
    id: reloadDelay
    interval: 300
    onTriggered: {
      root.loadModule()
      themeColors.reload()
      root.checkTheme()
    }
  }

  Component.onCompleted: {
    lastThemeColors = themeColors.text()
    loadModule()
  }

  // Disabling the plugin hands the borders back to the theme.
  Component.onDestruction: {
    Quickshell.execDetached(["hyprctl", "eval", "if AppColor and AppColor.shutdown then AppColor.shutdown() end"])
  }
}
