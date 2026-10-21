/*
 * SPDX-FileCopyrightText: 2026 linux-macos contributors
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Genie mesh implementation. See GenieModel.h for the algorithm reference.
 */

// Own
#include "GenieModel.h"

// std
#include <algorithm>
#include <cmath>

namespace
{

inline qreal lerp(qreal from, qreal to, qreal t)
{
    return from + (to - from) * t;
}

// Standard ease-in-out quad, used for the edge positions and for the
// distribution of the width contraction over the window rows.
inline qreal easeInOutQuad(qreal t)
{
    t = std::clamp(t, 0.0, 1.0);
    return t < 0.5 ? 2.0 * t * t : 1.0 - 2.0 * (1.0 - t) * (1.0 - t);
}

// Hermite smoothstep, used for the width contraction timing.
inline qreal smoothstep(qreal edge0, qreal edge1, qreal x)
{
    const qreal t = std::clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

} // namespace

GenieModel::GenieModel(KWin::EffectWindow *window)
    : m_window(window)
{
}

void GenieModel::setWindow(KWin::EffectWindow *window)
{
    m_window = window;
}

KWin::EffectWindow *GenieModel::window() const
{
    return m_window;
}

void GenieModel::setIconGeometry(const QRectF &rect)
{
    m_iconGeometry = rect;
}

QRectF GenieModel::iconGeometry() const
{
    return m_iconGeometry;
}

void GenieModel::setDirection(Direction direction)
{
    m_direction = direction;
}

Direction GenieModel::direction() const
{
    return m_direction;
}

void GenieModel::setParameters(const Parameters &parameters)
{
    m_parameters = parameters;
}

GenieModel::Parameters GenieModel::parameters() const
{
    return m_parameters;
}

void GenieModel::start(AnimationKind kind)
{
    m_timeLine.setDuration(m_parameters.duration);
    m_timeLine.setEasingCurve(QEasingCurve::Linear);
    m_timeLine.setDirection(kind == AnimationKind::Minimize
            ? KWin::TimeLine::Forward
            : KWin::TimeLine::Backward);
    m_timeLine.reset();
}

void GenieModel::toggleDirection()
{
    m_timeLine.toggleDirection();
}

bool GenieModel::running() const
{
    return m_timeLine.running();
}

void GenieModel::advance(const KWin::RenderView *view)
{
    m_timeLine.advance(view);
}

bool GenieModel::done() const
{
    return m_timeLine.done();
}

qreal GenieModel::progress() const
{
    return m_timeLine.value();
}

void GenieModel::apply(KWin::WindowQuadList &quads) const
{
    if (!m_window) {
        return;
    }

    const QRectF windowRect = m_window->frameGeometry();
    const QRectF iconRect = m_iconGeometry;
    if (windowRect.width() <= 0.0 || windowRect.height() <= 0.0
        || iconRect.width() <= 0.0 || iconRect.height() <= 0.0) {
        return;
    }

    // "p" is 0 for a normal window and 1 for a window that has been fully
    // swallowed by the dock icon.
    const qreal p = std::clamp(m_timeLine.value(), 0.0, 1.0);

    // The edge closest to the dock (the "near" edge) starts moving right away,
    // the opposite ("far") edge follows later. This is what makes the window
    // stretch towards the dock before it is sucked in.
    const qreal slideEnd = std::clamp(m_parameters.slideEnd, 0.05, 1.0);
    const qreal fallStart = std::clamp(m_parameters.fallStart, 0.0, 0.99);
    const qreal nearWidthEnd = std::clamp(m_parameters.nearWidthEnd, 0.05, 1.0);
    const qreal farWidthStart = std::clamp(m_parameters.farWidthStart, 0.0, 0.99);

    const qreal nearProgress = easeInOutQuad(std::clamp(p / slideEnd, 0.0, 1.0));
    const qreal farProgress = easeInOutQuad(std::clamp((p - fallStart) / (1.0 - fallStart), 0.0, 1.0));

    // The near edge contracts to the icon width first; the far edge only
    // starts contracting later, keeping the top edge wide and horizontal for
    // most of the animation.
    const qreal nearWidthProgress = smoothstep(0.0, nearWidthEnd, p);
    const qreal farWidthProgress = smoothstep(farWidthStart, 1.0, p);

    // Decompose the problem into a depth axis (far edge -> near edge) and a
    // lateral axis (the two remaining edges). This keeps one implementation
    // for bottom, top, left and right docks.
    const bool vertical = m_direction == Direction::Bottom || m_direction == Direction::Top;

    qreal winNear = 0.0;
    qreal iconNear = 0.0;
    qreal winFar = 0.0;
    qreal iconFar = 0.0;
    qreal winStart = 0.0;
    qreal iconStart = 0.0;
    qreal winEnd = 0.0;
    qreal iconEnd = 0.0;

    switch (m_direction) {
    case Direction::Bottom:
        winNear = windowRect.bottom();
        iconNear = iconRect.bottom();
        winFar = windowRect.top();
        iconFar = iconRect.top();
        winStart = windowRect.left();
        iconStart = iconRect.left();
        winEnd = windowRect.right();
        iconEnd = iconRect.right();
        break;
    case Direction::Top:
        winNear = windowRect.top();
        iconNear = iconRect.top();
        winFar = windowRect.bottom();
        iconFar = iconRect.bottom();
        winStart = windowRect.left();
        iconStart = iconRect.left();
        winEnd = windowRect.right();
        iconEnd = iconRect.right();
        break;
    case Direction::Left:
        winNear = windowRect.left();
        iconNear = iconRect.left();
        winFar = windowRect.right();
        iconFar = iconRect.right();
        winStart = windowRect.top();
        iconStart = iconRect.top();
        winEnd = windowRect.bottom();
        iconEnd = iconRect.bottom();
        break;
    case Direction::Right:
        winNear = windowRect.right();
        iconNear = iconRect.right();
        winFar = windowRect.left();
        iconFar = iconRect.left();
        winStart = windowRect.top();
        iconStart = iconRect.top();
        winEnd = windowRect.bottom();
        iconEnd = iconRect.bottom();
        break;
    }

    // Interpolated edge positions in global coordinates.
    const qreal nearEdge = lerp(winNear, iconNear, nearProgress);
    const qreal farEdge = lerp(winFar, iconFar, farProgress);

    for (KWin::WindowQuad &quad : quads) {
        for (int i = 0; i < 4; ++i) {
            KWin::WindowVertex &vertex = quad[i];

            // Convert the window-local quad vertex to global coordinates.
            const qreal x = windowRect.left() + vertex.x();
            const qreal y = windowRect.top() + vertex.y();

            // depth: 0 at the far edge, 1 at the near edge.
            // lateral: 0 at the start edge, 1 at the end edge.
            qreal depth = 0.0;
            qreal lateral = 0.0;
            switch (m_direction) {
            case Direction::Bottom:
                depth = (y - windowRect.top()) / windowRect.height();
                lateral = (x - windowRect.left()) / windowRect.width();
                break;
            case Direction::Top:
                depth = 1.0 - (y - windowRect.top()) / windowRect.height();
                lateral = (x - windowRect.left()) / windowRect.width();
                break;
            case Direction::Left:
                depth = 1.0 - (x - windowRect.left()) / windowRect.width();
                lateral = (y - windowRect.top()) / windowRect.height();
                break;
            case Direction::Right:
                depth = (x - windowRect.left()) / windowRect.width();
                lateral = (y - windowRect.top()) / windowRect.height();
                break;
            }

            // Rows near the dock contract earlier than rows far away; the
            // easing distributes the contraction smoothly over the window.
            const qreal rowT = easeInOutQuad(std::clamp(depth, 0.0, 1.0));
            const qreal widthProgress = lerp(farWidthProgress, nearWidthProgress, rowT);

            const qreal startEdge = lerp(winStart, iconStart, widthProgress);
            const qreal endEdge = lerp(winEnd, iconEnd, widthProgress);

            const qreal positionAlongDepth = lerp(farEdge, nearEdge, depth);
            const qreal positionAlongLateral = lerp(startEdge, endEdge, lateral);

            const qreal newX = vertical ? positionAlongLateral : positionAlongDepth;
            const qreal newY = vertical ? positionAlongDepth : positionAlongLateral;

            // Back to window-local coordinates.
            vertex.setX(newX - windowRect.left());
            vertex.setY(newY - windowRect.top());
        }
    }
}