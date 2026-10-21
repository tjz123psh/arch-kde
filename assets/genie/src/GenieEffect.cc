/*
 * SPDX-FileCopyrightText: 2026 linux-macos contributors
 * SPDX-FileCopyrightText: 2018 Vlad Zagorodniy <vladzzag@gmail.com>
 * SPDX-FileCopyrightText: 2026 Roy Bock <dev@si13n7.com>
 * SPDX-FileCopyrightText: 2008 Martin Graesslin <mgraesslin@kde.org>
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Lifecycle derived from "Yet Another Magic Lamp (reloaded)" and KWin's
 * Magic Lamp effect; the genie mesh is implemented in GenieModel.cc.
 */

// Own
#include "GenieEffect.h"

// kwineffects
#include <core/renderviewport.h>
#include <effect/effecthandler.h>

// KDE
#include <KConfigGroup>
#include <KSharedConfig>

// Qt
#include <QRegion>

// std
#include <cmath>

namespace
{

// Returns which screen edge a dock panel is closest to.
Direction dockEdge(KWin::EffectWindow *dock)
{
    KWin::LogicalOutput *screen = KWin::effects->screenAt(dock->frameGeometry().center().toPoint());
    if (!screen) {
        return Direction::Bottom;
    }
    const QRectF screenRect = KWin::effects->clientArea(KWin::FullScreenArea, screen);
    const QPointF c = dock->frameGeometry().center();

    const qreal l = qAbs(c.x() - screenRect.left());
    const qreal t = qAbs(c.y() - screenRect.top());
    const qreal r = qAbs(screenRect.right() - c.x());
    const qreal b = qAbs(screenRect.bottom() - c.y());
    const qreal m = qMin(qMin(l, t), qMin(r, b));

    if (qFuzzyCompare(l, m)) {
        return Direction::Left;
    }
    if (qFuzzyCompare(t, m)) {
        return Direction::Top;
    }
    if (qFuzzyCompare(r, m)) {
        return Direction::Right;
    }
    return Direction::Bottom;
}

// Returns the icon geometry on the screen that contains the window's center.
// When iconGeometry() points to a panel on a different screen (race condition
// with multiple task managers writing _NET_WM_ICON_GEOMETRY), the icon is
// remapped to the correct screen.
//
// Screen identity is determined via dock window pointers (always in global
// coordinates) rather than screenAt(iconRect.center()), which is unreliable
// when iconGeometry() uses screen-local coordinates (as on Wayland).
QRectF resolveIconGeometry(KWin::EffectWindow *w)
{
    const QRectF iconRect = w->iconGeometry();

    // Window center determines the authoritative screen (robust against
    // decorations extending a few pixels into an adjacent screen).
    KWin::LogicalOutput *primaryScreen = KWin::effects->screenAt(w->frameGeometry().center().toPoint());
    if (!primaryScreen) {
        return iconRect;
    }

    // Find which dock (panel) the iconGeometry falls into. Dock frameGeometry
    // is always in global coordinates, making this reliable regardless of
    // whether iconGeometry itself uses global or screen-local coordinates.
    KWin::EffectWindow *sourceDock = nullptr;
    for (KWin::EffectWindow *candidate : KWin::effects->stackingOrder()) {
        if (!candidate->isDock()) {
            continue;
        }
        // Use intersects, not contains: Plasma sometimes publishes icon
        // geometry slightly larger than the panel (KDE's Magic Lamp has the
        // same note).
        if (candidate->frameGeometry().intersects(iconRect)) {
            sourceDock = candidate;
            break;
        }
    }

    // If the dock containing the icon is already on the primary screen, the
    // iconGeometry is correct - use it directly.
    if (sourceDock) {
        KWin::LogicalOutput *sourceDockScreen = KWin::effects->screenAt(sourceDock->frameGeometry().center().toPoint());
        if (sourceDockScreen == primaryScreen) {
            return iconRect;
        }
    }

    // Icon is on the wrong screen. Find the best-matching dock on primaryScreen:
    // prefer the dock on the same edge as the source (so we pick the task bar,
    // not an unrelated status bar on screens with multiple panels).
    Direction preferredEdge = Direction::Bottom;
    if (sourceDock) {
        KWin::LogicalOutput *srcScreen = KWin::effects->screenAt(sourceDock->frameGeometry().center().toPoint());
        if (!srcScreen) {
            return iconRect;
        }
        const QRectF srcRect = KWin::effects->clientArea(KWin::FullScreenArea, srcScreen);
        const QRectF tgtRect = KWin::effects->clientArea(KWin::FullScreenArea, primaryScreen);

        const auto closestEdge = [](const QRectF &rect, const QPointF &p) -> Direction {
            const qreal l = qAbs(p.x() - rect.left());
            const qreal t = qAbs(p.y() - rect.top());
            const qreal r = qAbs(rect.right() - p.x());
            const qreal b = qAbs(rect.bottom() - p.y());
            const qreal m = qMin(qMin(l, t), qMin(r, b));
            if (qFuzzyCompare(l, m)) {
                return Direction::Left;
            }
            if (qFuzzyCompare(t, m)) {
                return Direction::Top;
            }
            if (qFuzzyCompare(r, m)) {
                return Direction::Right;
            }
            return Direction::Bottom;
        };
        const auto opposite = [](Direction d) -> Direction {
            switch (d) {
            case Direction::Top:
                return Direction::Bottom;
            case Direction::Bottom:
                return Direction::Top;
            case Direction::Left:
                return Direction::Right;
            case Direction::Right:
                return Direction::Left;
            }
            return Direction::Bottom;
        };

        const Direction srcFacingEdge = closestEdge(srcRect, tgtRect.center());
        const Direction tgtFacingEdge = closestEdge(tgtRect, srcRect.center());
        const Direction sourceDockEdge = dockEdge(sourceDock);
        preferredEdge = (sourceDockEdge == srcFacingEdge) ? tgtFacingEdge : opposite(tgtFacingEdge);
    }

    KWin::EffectWindow *targetDock = nullptr;
    KWin::EffectWindow *fallbackDock = nullptr;
    for (KWin::EffectWindow *candidate : KWin::effects->stackingOrder()) {
        if (!candidate->isDock()) {
            continue;
        }
        if (KWin::effects->screenAt(candidate->frameGeometry().center().toPoint()) != primaryScreen) {
            continue;
        }
        if (dockEdge(candidate) == preferredEdge) {
            targetDock = candidate;
            break;
        }
        if (!fallbackDock) {
            fallbackDock = candidate;
        }
    }
    if (!targetDock) {
        targetDock = fallbackDock;
    }
    if (!targetDock) {
        return iconRect;
    }

    if (!sourceDock) {
        const QRectF tgt = targetDock->frameGeometry();
        return QRectF(tgt.center().x() - iconRect.width() / 2,
            tgt.center().y() - iconRect.height() / 2,
            iconRect.width(), iconRect.height());
    }

    // Translate the icon by the offset between the two screens' origins so
    // that a button at local position (lx, ly) within the source panel appears
    // at the same local position within the target panel.
    KWin::LogicalOutput *sourceDockScreen = KWin::effects->screenAt(sourceDock->frameGeometry().center().toPoint());
    if (!sourceDockScreen) {
        return iconRect;
    }
    const QRectF srcScreenRect = KWin::effects->clientArea(KWin::FullScreenArea, sourceDockScreen);
    const QRectF tgtScreenRect = KWin::effects->clientArea(KWin::FullScreenArea, primaryScreen);

    const QPointF screenOffset = tgtScreenRect.topLeft() - srcScreenRect.topLeft();
    const QRectF translatedRect = iconRect.translated(screenOffset);

    // Clamp to the target dock so the icon stays within the panel.
    const QRectF tgt = targetDock->frameGeometry();
    const qreal cx = qBound(tgt.left() + iconRect.width() / 2,
        translatedRect.center().x(),
        tgt.right() - iconRect.width() / 2);
    const qreal cy = qBound(tgt.top() + iconRect.height() / 2,
        translatedRect.center().y(),
        tgt.bottom() - iconRect.height() / 2);
    return QRectF(cx - iconRect.width() / 2, cy - iconRect.height() / 2,
        iconRect.width(), iconRect.height());
}

// Fallback target when the dock does not publish _NET_WM_ICON_GEOMETRY.
// Quickshell-based docks (KOS shell) currently don't, and the old code kept a
// minimized window visible forever waiting for the icon rect: the user saw a
// window "collapse" and immediately reappear. Aim at the bottom-center of the
// work area instead - a slightly wrong genie is much better than a stuck window.
QRectF fallbackIconGeometry(KWin::EffectWindow *w)
{
    KWin::LogicalOutput *screen = KWin::effects->screenAt(w->frameGeometry().center().toPoint());
    if (!screen) {
        return QRectF();
    }
    const QRectF area = KWin::effects->clientArea(KWin::FullScreenArea, screen);
    const qreal iconSize = 48.0;
    return QRectF(area.center().x() - iconSize / 2.0,
        area.bottom() - iconSize,
        iconSize, iconSize);
}

// Determines the screen edge the genie target is attached to. Bottom docks
// (the macOS-like Latte Dock layout) are the primary use case; top, left and
// right docks are handled by the same mesh with swapped axes.
Direction resolveDirection(KWin::EffectWindow *w, const QRectF &iconRect)
{
    KWin::EffectWindow *panel = nullptr;
    for (KWin::EffectWindow *candidate : KWin::effects->stackingOrder()) {
        if (!candidate->isDock()) {
            continue;
        }
        if (candidate->frameGeometry().intersects(iconRect)) {
            panel = candidate;
            break;
        }
    }

    const QPointF windowCenter = w->frameGeometry().center();
    KWin::LogicalOutput *screen = KWin::effects->screenAt(windowCenter.toPoint());
    QRectF screenRect;
    if (screen) {
        screenRect = KWin::effects->clientArea(KWin::FullScreenArea, screen);
    }

    if (panel && !screenRect.isEmpty()) {
        const QRectF panelRect = panel->frameGeometry();
        if (panelRect.width() >= panelRect.height()) {
            // Horizontal panel: compare icon with the screen center.
            return iconRect.center().y() <= screenRect.center().y()
                ? Direction::Top
                : Direction::Bottom;
        }
        return iconRect.center().x() <= screenRect.center().x()
            ? Direction::Left
            : Direction::Right;
    }

    // No dock found (autohidden panel, no icon geometry, ...). Fall back to
    // the relative position of the icon.
    if (iconRect.center().y() >= windowCenter.y()) {
        return Direction::Bottom;
    }
    if (iconRect.center().y() <= windowCenter.y()) {
        return Direction::Top;
    }
    return iconRect.center().x() <= windowCenter.x() ? Direction::Left : Direction::Right;
}

} // namespace

GenieEffect::GenieEffect()
{
    reconfigure(ReconfigureAll);

    for (KWin::EffectWindow *w : KWin::effects->stackingOrder()) {
        slotWindowAdded(w);
    }

    connect(KWin::effects, &KWin::EffectsHandler::windowAdded,
        this, &GenieEffect::slotWindowAdded);
    connect(KWin::effects, &KWin::EffectsHandler::windowDeleted,
        this, &GenieEffect::slotWindowDeleted);
    connect(KWin::effects, &KWin::EffectsHandler::activeFullScreenEffectChanged,
        this, &GenieEffect::slotActiveFullScreenEffectChanged);

    // Keep the mesh curves smooth: no vertex snapping to integer device
    // coordinates while the genie deforms.
    setVertexSnappingMode(KWin::RenderGeometry::VertexSnappingMode::None);
}

GenieEffect::~GenieEffect() = default;

void GenieEffect::reconfigure(ReconfigureFlags flags)
{
    Q_UNUSED(flags)

    KConfigGroup group = KWin::effects->config()->group(QStringLiteral("Effect-LinuxMacOSGenie"));

    const int configuredDuration = group.readEntry(QStringLiteral("Duration"), 700);
    m_duration = animationTime(std::chrono::milliseconds(configuredDuration > 0 ? configuredDuration : 700));
    m_gridResolution = qBound(1, group.readEntry(QStringLiteral("GridResolution"), 50), 200);

    m_modelParameters.duration = m_duration;
    m_modelParameters.slideEnd = group.readEntry(QStringLiteral("SlideEnd"), 0.55);
    m_modelParameters.fallStart = group.readEntry(QStringLiteral("FallStart"), 0.35);
    m_modelParameters.nearWidthEnd = group.readEntry(QStringLiteral("NearWidthEnd"), 0.65);
    m_modelParameters.farWidthStart = group.readEntry(QStringLiteral("FarWidthStart"), 0.45);
}

void GenieEffect::prePaintScreen(KWin::ScreenPrePaintData &data)
{
    data.mask |= PAINT_SCREEN_WITH_TRANSFORMED_WINDOWS;
    KWin::effects->prePaintScreen(data);
}

void GenieEffect::prePaintWindow(KWin::RenderView *view, KWin::EffectWindow *w, KWin::WindowPrePaintData &data)
{
    const auto it = m_animations.find(w);
    if (it != m_animations.end()) {
        it->model.advance(view);
        data.setTransformed();
    }

    KWin::effects->prePaintWindow(view, w, data);
}

void GenieEffect::postPaintScreen()
{
    for (auto it = m_animations.begin(); it != m_animations.end();) {
        if (it->model.done()) {
            unredirect(it.key());
            it = m_animations.erase(it);
        } else {
            ++it;
        }
    }

    KWin::effects->addRepaintFull();
    KWin::effects->postPaintScreen();
}

QRegion GenieEffect::clipRegionFor(const GenieModel &model, KWin::EffectWindow *w) const
{
    const QRectF icon = model.iconGeometry();
    if (!icon.isValid()) {
        return QRegion();
    }

    const QRectF screenRect = KWin::effects->clientArea(KWin::ScreenArea, w);
    const QRectF workArea = KWin::effects->clientArea(KWin::FullScreenArea, w);

    // The visible part of the panel starts where the work area ends. Latte
    // publishes icon geometry slightly larger than the panel, so clamp to the
    // work area when it is meaningful and fall back to the icon edge.
    QRectF aboveDock = screenRect;
    switch (model.direction()) {
    case Direction::Bottom: {
        const qreal dockTop = qBound(screenRect.top(), qMin(workArea.bottom(), icon.top()), screenRect.bottom());
        aboveDock.setBottom(dockTop);
        break;
    }
    case Direction::Top: {
        const qreal dockBottom = qBound(screenRect.top(), qMax(workArea.top(), icon.bottom()), screenRect.bottom());
        aboveDock.setTop(dockBottom);
        break;
    }
    case Direction::Left: {
        const qreal dockRight = qBound(screenRect.left(), qMin(workArea.right(), icon.left()), screenRect.right());
        aboveDock.setRight(dockRight);
        break;
    }
    case Direction::Right: {
        const qreal dockLeft = qBound(screenRect.left(), qMax(workArea.left(), icon.right()), screenRect.right());
        aboveDock.setLeft(dockLeft);
        break;
    }
    }

    QRegion region(aboveDock.toAlignedRect());
    region += icon.toAlignedRect();
    region &= screenRect.toAlignedRect();
    return region;
}

bool GenieEffect::paintWindow(const KWin::RenderTarget &renderTarget,
    const KWin::RenderViewport &viewport,
    KWin::EffectWindow *w, int mask,
    const KWin::Region &region,
    KWin::WindowPaintData &data)
{
    const auto it = m_animations.constFind(w);
    if (it != m_animations.constEnd()) {
        // The screen is painted with PAINT_SCREEN_WITH_TRANSFORMED_WINDOWS, so
        // the scene would hand this window an infinite device region. Clip the
        // genie to the area above the dock plus the icon rectangle: while the
        // tail dives into the dock it paints outside the original frame, and
        // the transparent Latte panel would otherwise reveal it.
        const QRegion clipLogical = clipRegionFor(it->model, w);
        if (!clipLogical.isEmpty()) {
            const KWin::Region clip = viewport.mapToDeviceCoordinatesAligned(KWin::Region(clipLogical));
            return KWin::effects->paintWindow(renderTarget, viewport, w, mask, clip, data);
        }
    }

    return KWin::effects->paintWindow(renderTarget, viewport, w, mask, region, data);
}

void GenieEffect::apply(KWin::EffectWindow *window, int mask, KWin::WindowPaintData &data, KWin::WindowQuadList &quads)
{
    Q_UNUSED(mask)
    Q_UNUSED(data)

    const auto it = m_animations.constFind(window);
    if (it == m_animations.constEnd()) {
        return;
    }

    // One column is sufficient: for a fixed row the mesh is linear in x, so the
    // left and right vertex of every row define the whole row exactly.
    quads = quads.makeRegularGrid(1, m_gridResolution);
    it->model.apply(quads);
}

bool GenieEffect::isActive() const
{
    return !m_animations.isEmpty();
}

bool GenieEffect::supported()
{
    return OffscreenEffect::supported() && KWin::effects->animationsSupported();
}

void GenieEffect::slotWindowAdded(KWin::EffectWindow *w)
{
    connect(w, &KWin::EffectWindow::minimizedChanged,
        this, &GenieEffect::slotMinimizedChanged);
}

void GenieEffect::slotMinimizedChanged(KWin::EffectWindow *w)
{
    if (w->isMinimized()) {
        startMinimize(w);
    } else {
        startUnminimize(w);
    }
}

void GenieEffect::startMinimize(KWin::EffectWindow *w)
{
    if (KWin::effects->activeFullScreenEffect()) {
        return;
    }

    QRectF iconRect = resolveIconGeometry(w);
    if (!iconRect.isValid()) {
        iconRect = fallbackIconGeometry(w);
    }
    if (!iconRect.isValid()) {
        // No screen at all: leave the normal minimize path alone.
        return;
    }

    GenieAnimation &animation = m_animations[w];
    if (animation.model.running()) {
        animation.model.toggleDirection();
    } else {
        animation.model.setWindow(w);
        animation.model.setParameters(m_modelParameters);
        animation.model.setIconGeometry(iconRect);
        animation.model.setDirection(resolveDirection(w, iconRect));
        animation.model.start(GenieModel::AnimationKind::Minimize);
        animation.visibleRef.emplace(w, KWin::EffectWindow::PAINT_DISABLED_BY_MINIMIZE);
    }

    redirect(w);
    KWin::effects->addRepaintFull();
}

void GenieEffect::startUnminimize(KWin::EffectWindow *w)
{
    if (KWin::effects->activeFullScreenEffect()) {
        return;
    }

    QRectF iconRect = resolveIconGeometry(w);
    if (!iconRect.isValid()) {
        iconRect = fallbackIconGeometry(w);
    }
    if (!iconRect.isValid()) {
        return;
    }

    GenieAnimation &animation = m_animations[w];
    if (animation.model.running()) {
        animation.model.toggleDirection();
    } else {
        animation.model.setWindow(w);
        animation.model.setParameters(m_modelParameters);
        animation.model.setIconGeometry(iconRect);
        animation.model.setDirection(resolveDirection(w, iconRect));
        animation.model.start(GenieModel::AnimationKind::Unminimize);
    }

    redirect(w);
    KWin::effects->addRepaintFull();
}

void GenieEffect::slotWindowDeleted(KWin::EffectWindow *w)
{
    m_animations.remove(w);
}

void GenieEffect::slotActiveFullScreenEffectChanged()
{
    if (KWin::effects->activeFullScreenEffect() != nullptr) {
        for (auto it = m_animations.constBegin(); it != m_animations.constEnd(); ++it) {
            unredirect(it.key());
        }
        m_animations.clear();
    }
}