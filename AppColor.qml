import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar button: shows whether app-coloured floating borders are on, and
// toggles them on click. bin/appcolor calls
// `omarchy-shell io.github.tuladhar.appcolor refresh` when SUPER+ALT+B
// changes the state, so the button follows.
BarWidget {
  id: root
  moduleName: "io.github.tuladhar.appcolor"

  readonly property string bin: decodeURIComponent(String(Qt.resolvedUrl("bin/appcolor")).replace(/^file:\/\//, ""))
  property bool on: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function toggle() {
    if (!toggleProc.running) toggleProc.running = true
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  ShellIpc {
    target: "io.github.tuladhar.appcolor"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  Process {
    id: statusProc
    command: [root.bin, "status"]
    onExited: function(exitCode) { root.on = exitCode === 0 }
  }

  Process {
    id: toggleProc
    command: [root.bin, "toggle"]
    onExited: root.refresh()
  }

  Component.onCompleted: refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰏘"
    slotSize: Style.bar.statusSlot
    active: root.on
    useActiveColor: true
    opacity: root.on ? 1 : 0.45
    tooltipText: root.on ? strings.t("tooltip.on") : strings.t("tooltip.off")
    onPressed: root.toggle()
  }
}
