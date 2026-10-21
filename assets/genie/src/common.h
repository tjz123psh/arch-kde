/*
 * SPDX-FileCopyrightText: 2018 Vlad Zagorodniy <vladzzag@gmail.com>
 * SPDX-FileCopyrightText: 2026 linux-macos contributors
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * This file is derived from "Yet Another Magic Lamp (reloaded)"
 * (https://github.com/koryboc/kwin-effects-yet-another-magic-lamp-reloaded,
 * GPL-2.0-or-later) and from KWin's built-in Magic Lamp effect.
 * The linux-macos project as a whole is distributed under GPL-3.0-or-later;
 * GPL-2.0-or-later sources are compatible with it.
 */

#pragma once

/**
 * The screen edge a dock (panel) or a minimize target is attached to.
 **/
enum class Direction {
    Left,
    Top,
    Right,
    Bottom
};
