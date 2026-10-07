#!/bin/bash
# Copy the plugin into the Omarchy shell's plugin directory. The validator
# rejects symlinks, so this copies rather than links. Pass --enable to place
# the widget in the bar.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/av.news"

omarchy plugin validate "$src" >/dev/null

mkdir -p "$dest/bin"
install -m 644 "$src/manifest.json" "$src/BarWidget.qml" "$src/NewsPanel.qml" "$src/README.md" "$dest/"
install -m 755 "$src/bin/av-news-fetch" "$dest/bin/"
echo "Installed to $dest"

omarchy-shell shell rescanPlugins >/dev/null
if [[ ${1-} == --enable ]]; then
  omarchy plugin enable av.news --section left
fi
