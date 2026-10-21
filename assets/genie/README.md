# linux-macos genie effect

A native KWin 6.8 effect that implements the macOS "genie" minimize/restore
animation, replacing the funnel-shaped Yet Another Magic Lamp build that this
repository used before.

* Effect id: `kwin4_effect_linuxmacosgenie`
* Plugin file: `/usr/lib/qt6/plugins/kwin/effects/plugins/kwin4_effect_linuxmacosgenie.so`
* License: GPL-2.0-or-later (compatible with the project's GPL-3.0-or-later)
* KWin API target: KWin 6.8 (the hook signatures match 6.8 exactly; 6.7 and
  older are not supported by this checkout of the plugin)

## What it does

Instead of squashing the window into a funnel around a point, the window is
mapped through a fine vertical mesh whose rows are moved and scaled
independently:

* the edge closest to the dock starts moving and narrowing immediately;
* the opposite edge stays horizontal and keeps its width for most of the
  animation;
* the sides become concave curves because the width contraction is distributed
  over the rows with an ease-in-out curve;
* at the end the whole window lands exactly on the dock icon rectangle.

The animation is driven by one `KWin::TimeLine` per window. Minimize runs it
forward (progress 0 -> 1), restore runs it backward (1 -> 0); an interrupted
animation is reversed with `TimeLine::toggleDirection()`.

## Build and install

Dependencies (Arch): `cmake`, `extra-cmake-modules`, `kwin` (headers),
`qt6-base`, `kconfig`, `kcoreaddons`.

```sh
cmake -S kwin-effects/linux-macos-genie -B kwin-effects/linux-macos-genie/build \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build kwin-effects/linux-macos-genie/build -j"$(nproc)"
sudo cmake --install kwin-effects/linux-macos-genie/build
```

The repository helper `tools/build-genie-effect.sh` wraps these commands and
falls back to the old reloaded-magic-lamp build if this plugin cannot be
compiled:

```sh
./tools/build-genie-effect.sh              # new genie first, legacy as fallback
./tools/build-genie-effect.sh --configure  # also write kwinrc + reload the effect
```

## Enable

```sh
kwriteconfig6 --file kwinrc --group Plugins --key kwin4_effect_linuxmacosgenieEnabled true
kwriteconfig6 --file kwinrc --group Plugins --key magiclampEnabled false
kwriteconfig6 --file kwinrc --group Plugins --key libkwin4_effect_yetanothermagiclampEnabled false
qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect kwin4_effect_linuxmacosgenie
qdbus6 org.kde.KWin /KWin reconfigure
```

## Configuration

Settings live in `kwinrc`; KWin calls `reconfigure()` when the file changes:

```ini
[Effect-LinuxMacOSGenie]
Duration=700
GridResolution=50
SlideEnd=0.55
FallStart=0.35
NearWidthEnd=0.65
FarWidthStart=0.45
```

* `Duration` - animation duration in milliseconds, default `700`. The global
  `[KDE] AnimationDurationFactor` is applied on top of it (useful for
  frame-by-frame captures; `8` turns 700 ms into 5.6 s).
* `GridResolution` - number of horizontal rows of the deformation mesh,
  default `50` (each row is one quad; one column is enough because the mesh is
  linear along x). Clamped to 1..200.
* `SlideEnd` - progress at which the near (dock side) edge reaches the icon,
  default `0.55`.
* `FallStart` - progress at which the far edge starts falling, default
  `0.35`. Raising it keeps the top edge in place longer.
* `NearWidthEnd` - progress at which the near edge has contracted to the icon
  width, default `0.65`.
* `FarWidthStart` - progress at which the far edge starts contracting,
  default `0.45`. Raising it keeps the top edge closer to full width for
  longer.

All four shape parameters are clamped to sane ranges in `GenieModel::apply()`.

There is no KCM; values are read directly from `kwinrc`.

## Implementation notes

* `OffscreenEffect` redirects the window into a texture; `apply()` rewrites
  the vertices of `quads.makeRegularGrid(1, GridResolution)`.
* Window quads are in window-local coordinates with the origin at
  `frameGeometry().topLeft()`. The mesh converts them to global coordinates
  because `iconGeometry()` and `frameGeometry()` are global, then converts the
  result back.
* The target icon rectangle comes from `iconGeometry()`, remapped to the
  screen of the window when a second panel publishes stale coordinates
  (the same helper that the reloaded magic lamp used). If the icon geometry is
  not available yet (Wayland panels publish it asynchronously), the window gets
  a `EffectWindowVisibleRef` and the animation is retried after 150 ms.
* `paintWindow()` clips the genie to the work area plus the icon rectangle.
  Without that, the tail would be visible through Latte's translucent panel
  while it dives into the dock.
* Bottom docks are the primary target (the WhiteSur/Latte layout). Top, left
  and right docks are handled by the same mesh with swapped axes, but only the
  bottom case was verified on the demo VM.

Qt caches plugin libraries per file path. If the effect is already loaded,
rebuilding and reinstalling it does **not** replace the running code; restart
KWin (log out and back in, or start a fresh session) for a new build to take
effect. Unloading and loading the effect again is not always enough because the
old library stays mapped.

## Verification (demo VM, KWin 6.8.0)

Captured with `AnimationDurationFactor=8` (700 ms -> 5.6 s) so that
`spectacle` could sample the animation. The real 700 ms duration was verified
separately with `AnimationDurationFactor=1`: the effect logged
`duration 700` for the same config.

* Session test id: `genie-dev4` (`genie-dev4.so`, same binary as the real
  `kwin4_effect_linuxmacosgenie.so`). The real-name plugin is installed; it
  becomes active on the next login because Qt keeps the already-loaded library
  of the same path.
* Target: Dolphin -> Latte dock icon, icon geometry `(790,1000 68x80)`.
* Evidence:
  * `/tmp/genie-final/final-min-contact.png` - minimize key frames
    (p ~0.3 / 0.55 / 0.75 / 0.93)
  * `/tmp/genie-final/final-restore-contact.png` - restore key frames
    (p ~0.7 / 0.5 / 0.3 / 0.1)
  * `/tmp/genie-final/contact-vs-reference.png` - key frames next to
    `refs/macos-assets/04_animations/01_macos_genie_effect_in.gif`
  * `/tmp/genie-final/genie-slowmo.gif` - slow-motion minimize sequence
  * `/tmp/genie-final/keyframes/mid-p50-big.png` - full-resolution mid funnel
* VM config used: `Duration=700`, `GridResolution=50`, shape parameters at
  their defaults (`SlideEnd=0.55`, `FallStart=0.35`, `NearWidthEnd=0.65`,
  `FarWidthStart=0.45`).
* `AnimationDurationFactor` was restored to 1 after the capture.

## Credits

The effect lifecycle (`OffscreenEffect`, `EffectWindowVisibleRef`, pending
icon geometry resolution, pre-paint/post-paint bookkeeping) is derived from:

* KWin's built-in Magic Lamp effect,
  Copyright (C) 2008 Martin Gräßlin, GPL-2.0-or-later;
* "Yet Another Magic Lamp (reloaded)" by Vlad Zagorodniy and Roy Bock,
  GPL-2.0-or-later.

The genie mesh is an independent implementation of the algorithm published by
Harshil Shah in "Recreating the macOS Genie Effect"
(<https://harshil.net/blog/recreating-the-mac-genie-effect>,
<https://github.com/HarshilShah/Genie>). The animation algorithm itself is not
copyrightable and no code was copied from that project. The project as a whole
is distributed under GPL-3.0-or-later; GPL-2.0-or-later code is compatible with
it.