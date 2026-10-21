# SPDX-License-Identifier: GPL-3.0-or-later
add_library(kwin4_effect_linuxmacosgenie SHARED
    GenieEffect.cc
    GenieModel.cc
    plugin.cc
)

# KWin 6.8 derives the effect id from the plugin file name when KPlugin.Id is
# absent, and warns when the two disagree. KPlugin.Id in metadata.json is
# "kwin4_effect_linuxmacosgenie", so the library file must have exactly the
# same name - no "lib" prefix.
set_target_properties(kwin4_effect_linuxmacosgenie PROPERTIES
    PREFIX ""
)

target_link_libraries(kwin4_effect_linuxmacosgenie
    Qt6::Core
    Qt6::Gui
    KF6::ConfigCore
    KF6::CoreAddons
    KWin::kwin
)

install(
    TARGETS
        kwin4_effect_linuxmacosgenie
    DESTINATION
        ${KDE_INSTALL_QTPLUGINDIR}/kwin/effects/plugins/
)
