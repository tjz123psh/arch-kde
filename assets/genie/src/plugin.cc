/*
 * SPDX-FileCopyrightText: 2026 linux-macos contributors
 * SPDX-FileCopyrightText: 2018 Vlad Zagorodniy <vladzzag@gmail.com>
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

// Own
#include "GenieEffect.h"

KWIN_EFFECT_FACTORY_SUPPORTED_ENABLED(GenieEffect,
    "metadata.json",
    return GenieEffect::supported();
    ,
    return false;)

#include "plugin.moc"
