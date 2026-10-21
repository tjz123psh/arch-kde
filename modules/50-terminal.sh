#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

setup_terminal() {
  log "配置 kitty / fish / starship..."
  install_file "$CONFIG_DIR/kitty/kitty.conf" "$HOME/.config/kitty/kitty.conf"
  install_file "$CONFIG_DIR/kitty/macos.conf" "$HOME/.config/kitty/themes/macos.conf"
  install_file "$CONFIG_DIR/fish/kos.fish" "$HOME/.config/fish/conf.d/kos.fish"
  install_file "$CONFIG_DIR/starship.toml" "$HOME/.config/starship.toml"
}
