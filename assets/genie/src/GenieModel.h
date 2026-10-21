/*
 * SPDX-FileCopyrightText: 2026 linux-macos contributors
 * SPDX-FileCopyrightText: 2018 Vlad Zagorodniy <vladzzag@gmail.com>
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Genie deformation model. The lifecycle (window, icon geometry, timeline)
 * follows KWin's Magic Lamp effect; the mesh itself is a new implementation of
 * the classic macOS genie, based on the publicly documented recreation by
 * Harshil Shah:
 *   https://harshil.net/blog/recreating-the-mac-genie-effect
 *   https://github.com/HarshilShah/Genie
 * The animation algorithm itself is not copyrightable; no code was copied
 * from that project.
 */

#pragma once

// Own
#include "common.h"

// kwineffects
#include <effect/effectwindow.h>
#include <effect/timeline.h>
#include <scene/itemgeometry.h>

// std
#include <chrono>

namespace KWin
{
class RenderView;
}

/**
 * Model for the genie animation.
 *
 * The model maps a grid of vertices of the window texture into a "genie"
 * shape that funnels the window into the icon rectangle of a dock. Quads are
 * in window-local coordinates (origin at frameGeometry().topLeft()); the
 * model converts them to global coordinates internally, because iconGeometry()
 * and frameGeometry() are global.
 **/
class GenieModel
{
public:
    struct Parameters {
        // Total duration of the animation.
        std::chrono::milliseconds duration{std::chrono::milliseconds(700)};

        // Progress (0..1) at which the near edge has reached the icon.
        qreal slideEnd = 0.55;
        // Progress (0..1) at which the far edge starts falling.
        qreal fallStart = 0.35;
        // Progress (0..1) at which the near edge has contracted to icon width.
        qreal nearWidthEnd = 0.65;
        // Progress (0..1) at which the far edge starts contracting.
        qreal farWidthStart = 0.45;
    };

    /**
     * Kinds of animation supported by the model.
     **/
    enum class AnimationKind {
        Minimize,
        Unminimize
    };

    explicit GenieModel(KWin::EffectWindow *window = nullptr);

    void setWindow(KWin::EffectWindow *window);
    KWin::EffectWindow *window() const;

    void setIconGeometry(const QRectF &rect);
    QRectF iconGeometry() const;

    void setDirection(Direction direction);
    Direction direction() const;

    void setParameters(const Parameters &parameters);
    Parameters parameters() const;

    /**
     * Starts the animation. Minimize runs the timeline forward (progress 0 -> 1),
     * unminimize runs it backward (progress 1 -> 0).
     **/
    void start(AnimationKind kind);

    /**
     * Reverses the timeline, e.g. when a window is restored before its
     * minimize animation has finished.
     **/
    void toggleDirection();

    /**
     * Returns whether the timeline is currently between its endpoints.
     **/
    bool running() const;

    /**
     * Advances the timeline to the presentation timestamp of @p view.
     **/
    void advance(const KWin::RenderView *view);

    /**
     * Returns whether the animation has reached its target position.
     **/
    bool done() const;

    /**
     * Returns the current animation progress: 0 = normal window, 1 = window
     * fully collapsed into the icon.
     **/
    qreal progress() const;

    /**
     * Applies the current state of the model to @p quads.
     **/
    void apply(KWin::WindowQuadList &quads) const;

private:
    KWin::EffectWindow *m_window = nullptr;
    QRectF m_iconGeometry;
    Direction m_direction = Direction::Bottom;
    Parameters m_parameters;
    KWin::TimeLine m_timeLine{std::chrono::milliseconds(700)};
};