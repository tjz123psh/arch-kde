import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.desktop.modules.common
import qs.desktop.modules.dock
import "../../../Kos/Ui"

// Bottom-centre feedback surface. It is deliberately click-through: a volume
// key must never leave an invisible 360x84 input trap over the desktop.
PanelWindow {
    id: root

    property var targetScreen: null

    screen: targetScreen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "kos-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors {
        bottom: true
        left: true
        right: true
    }
    margins.bottom: 96
    implicitHeight: 96
    visible: OsdService.visible && targetScreen !== null

    Item {
        id: noInput
        width: 0
        height: 0
    }
    mask: Region { item: noInput }

    Item {
        id: card
        anchors.centerIn: parent
        width: Math.min(360, Math.max(280, root.width - 32))
        height: 84
        opacity: OsdService.visible ? 1 : 0
        scale: OsdService.visible ? 1 : 0.96
        Accessible.name: OsdService.kind === "brightness"
            ? qsTr("屏幕亮度 %1%").arg(OsdService.percent)
            : (OsdService.muted ? qsTr("音量已静音") : qsTr("音量 %1%").arg(OsdService.percent))

        Behavior on opacity {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        Behavior on scale {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        LiquidGlassPanel {
            anchors.fill: parent
            radius: 22
            cornerExponent: AppearanceTokens.shape.cornerExponent
            blurAnchor: card
            scrimEnabled: AppearanceTokens.surface.usesBackdrop
            scrimLevel: "balanced"
            baseColor: ThemeService.isDark
                ? Qt.rgba(0.08, 0.09, 0.12, 0.44)
                : Qt.rgba(0.95, 0.95, 0.98, 0.58)
            ambientPrimary: WallpaperColorSource.primary
            ambientSecondary: WallpaperColorSource.secondary
            ambientStrength: 0.30 * AppearanceTokens.glass.ambientMultiplier
        }

        OsdGlyph {
            id: glyph
            x: 20
            y: 27
            kind: OsdService.kind
            muted: OsdService.muted
            ink: ThemeService.foregroundColor
        }

        Text {
            id: title
            x: 58
            y: 16
            text: OsdService.kind === "brightness" ? qsTr("亮度") : qsTr("音量")
            color: ThemeService.secondaryForegroundColor
            font.pixelSize: 12
            font.weight: Font.Medium
        }

        Text {
            id: value
            anchors {
                right: parent.right
                rightMargin: 20
                top: parent.top
                topMargin: 12
            }
            text: OsdService.muted ? qsTr("静音") : OsdService.percent + "%"
            color: ThemeService.foregroundColor
            font.pixelSize: 18
            font.weight: Font.DemiBold
        }

        Rectangle {
            id: track
            x: 58
            y: 49
            width: parent.width - 78
            height: 5
            radius: 2.5
            color: ThemeService.isDark ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(0, 0, 0, 0.12)

            Rectangle {
                width: parent.width * Math.max(0, Math.min(100, OsdService.percent)) / 100
                height: parent.height
                radius: parent.radius
                color: ThemeService.accentColor
                Behavior on width {
                    NumberAnimation { duration: 80; easing.type: Easing.OutCubic }
                }
            }
        }
    }
}
