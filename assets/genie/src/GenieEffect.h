/*
 * SPDX-FileCopyrightText: 2026 linux-macos contributors
 * SPDX-FileCopyrightText: 2018 Vlad Zagorodniy <vladzzag@gmail.com>
 * SPDX-FileCopyrightText: 2026 Roy Bock <dev@si13n7.com>
 * SPDX-FileCopyrightText: 2008 Martin Graesslin <mgraesslin@kde.org>
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The effect lifecycle (OffscreenEffect, EffectWindowVisibleRef, pending
 * iconGeometry resolution, prePaint/postPaint handling) is derived from
 * "Yet Another Magic Lamp (reloaded)" (GPL-2.0-or-later) and from KWin's
 * built-in Magic Lamp effect (GPL-2.0-or-later). The deformation model is
 * replaced with a macOS-style genie mesh, see GenieModel.h.
 */

#pragma once

// Own
#include "GenieModel.h"

// kwineffects
#include <effect/offscreeneffect.h>

// Qt
#include <QMap>

// std
#include <chrono>
#include <optional>

/**
 * Per-window state of a running genie animation.
 **/
struct GenieAnimation {
    GenieModel model;
    // Keeps a minimized window visible while its genie animation is running.
    std::optional<KWin::EffectWindowVisibleRef> visibleRef;
};

/**
 * macOS-style genie minimize/unminimize effect.
 *
 * The window is deformed into a funnel whose near edge is pulled into the
 * icon geometry published by the dock. Unlike the magic lamp effect, the
 * near edge narrows first while the far edge stays wide, which produces the
 * characteristic curved sides and the "horizontal top edge" look of the
 * macOS genie.
 **/
class GenieEffect : public KWin::OffscreenEffect
{
    Q_OBJECT

public:
    GenieEffect();
    ~GenieEffect() override;

    void reconfigure(ReconfigureFlags flags) override;

    void prePaintScreen(KWin::ScreenPrePaintData &data) override;
    void prePaintWindow(KWin::RenderView *view, KWin::EffectWindow *w, KWin::WindowPrePaintData &data) override;
    void postPaintScreen() override;

    bool paintWindow(const KWin::RenderTarget &renderTarget, const KWin::RenderViewport &viewport,
        KWin::EffectWindow *w, int mask, const KWin::Region &region,
        KWin::WindowPaintData &data) override;

    bool isActive() const override;
    int requestedEffectChainPosition() const override;

    static bool supported();

protected:
    void apply(KWin::EffectWindow *window, int mask, KWin::WindowPaintData &data, KWin::WindowQuadList &quads) override;

private Q_SLOTS:
    void slotWindowAdded(KWin::EffectWindow *w);
    void slotMinimizedChanged(KWin::EffectWindow *w);
    void slotWindowDeleted(KWin::EffectWindow *w);
    void slotActiveFullScreenEffectChanged();

private:
    void startMinimize(KWin::EffectWindow *w);
    void startUnminimize(KWin::EffectWindow *w);

    // Region the genie is allowed to paint into. The part of the tail that
    // would be behind the dock panel is masked, except for the icon rectangle
    // itself, so the window visibly disappears into the dock icon instead of
    // showing through a translucent panel.
    QRegion clipRegionFor(const GenieModel &model, KWin::EffectWindow *w) const;

    std::chrono::milliseconds m_duration{std::chrono::milliseconds(700)};
    int m_gridResolution = 50;
    GenieModel::Parameters m_modelParameters;

    QMap<KWin::EffectWindow *, GenieAnimation> m_animations;
    // Windows waiting for iconGeometry to become valid before the animation starts.
    QMap<KWin::EffectWindow *, KWin::EffectWindowVisibleRef> m_pendingMinimize;
};

inline int GenieEffect::requestedEffectChainPosition() const
{
    return 50;
}