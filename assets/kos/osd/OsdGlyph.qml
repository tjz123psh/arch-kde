import QtQuick

// Small, theme-agnostic speaker/sun glyph. Drawn instead of loading a themed
// icon so the OSD cannot end up with a dark icon on dark glass.
Canvas {
    id: root

    property string kind: "volume"
    property bool muted: false
    property color ink: "#ffffff"

    width: 26
    height: 26
    antialiasing: true
    opacity: 0.94

    onKindChanged: requestPaint()
    onMutedChanged: requestPaint()
    onInkChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        const color = String(root.ink)
        ctx.reset()
        ctx.strokeStyle = color
        ctx.fillStyle = color
        ctx.lineWidth = 1.7
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        if (root.kind === "brightness") {
            ctx.beginPath()
            ctx.arc(13, 13, 4.1, 0, Math.PI * 2)
            ctx.fill()
            for (let i = 0; i < 8; ++i) {
                const a = i * Math.PI / 4
                ctx.beginPath()
                ctx.moveTo(13 + Math.cos(a) * 7.2, 13 + Math.sin(a) * 7.2)
                ctx.lineTo(13 + Math.cos(a) * 10.8, 13 + Math.sin(a) * 10.8)
                ctx.stroke()
            }
            return
        }

        // Speaker body.
        ctx.beginPath()
        ctx.moveTo(2.8, 10.2)
        ctx.lineTo(7.0, 10.2)
        ctx.lineTo(11.0, 6.0)
        ctx.lineTo(11.0, 20.0)
        ctx.lineTo(7.0, 15.8)
        ctx.lineTo(2.8, 15.8)
        ctx.closePath()
        ctx.fill()

        if (root.muted) {
            ctx.lineWidth = 2.0
            ctx.beginPath()
            ctx.moveTo(3.5, 3.5)
            ctx.lineTo(22.5, 22.5)
            ctx.stroke()
            return
        }

        ctx.beginPath()
        ctx.arc(12.0, 13.0, 5.2, -0.82, 0.82)
        ctx.stroke()
        ctx.beginPath()
        ctx.arc(12.0, 13.0, 9.0, -0.70, 0.70)
        ctx.stroke()
    }
}
