# Homebrew cask template for hyprMac. `version` and `sha256` are placeholders:
# fill them from a GitHub release with scripts/release/cask.sh (see README.md).
cask "hyprmac" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Codesmith28/hyprMac/releases/download/v#{version}/hyprMac-#{version}.zip"
  name "hyprMac"
  desc "Hyprland-style tiling window manager that keeps macOS native Spaces"
  homepage "https://github.com/Codesmith28/hyprMac"

  depends_on macos: ">= :sonoma"

  app "hyprMac.app"

  # The release is ad-hoc signed and not notarized, so Gatekeeper would block the
  # quarantined download. This clears the flag on the app only.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/hyprMac.app"]
  end

  uninstall quit: "dev.codesmith28.hyprmac"

  zap trash: [
    "~/.config/hyprmac",
    "~/Library/Application Support/hyprMac",
    "~/Library/Caches/dev.codesmith28.hyprmac",
    "~/Library/LaunchAgents/dev.codesmith28.hyprmac.plist",
    "~/Library/Logs/hyprMac",
    "~/Library/Preferences/dev.codesmith28.hyprmac.plist",
  ]
end
