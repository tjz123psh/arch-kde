# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the in-repo macOS-style genie KWin effect for KWin 6.8.
# Upstream lifecycle inspiration: "Yet Another Magic Lamp (reloaded)" and
# KWin's Magic Lamp effect, both GPL-2.0-or-later.
cmake_minimum_required(VERSION 3.20)

project(linux-macos-genie VERSION 0.1.0 LANGUAGES CXX)

set(KF_MIN_VERSION "6.0")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)

find_package(ECM ${KF_MIN_VERSION} REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH
    ${CMAKE_MODULE_PATH}
    ${ECM_MODULE_PATH}
)

include(FeatureSummary)
include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)

find_package(Qt6 REQUIRED COMPONENTS
    Core
    Gui
    Widgets
)

find_package(KF6 ${KF_MIN_VERSION} REQUIRED COMPONENTS
    Config
    CoreAddons
)

find_package(KWin REQUIRED)

add_subdirectory(src)

feature_summary(WHAT ALL)
