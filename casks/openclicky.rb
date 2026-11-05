# Dormant until the project is enrolled in the Apple Developer Program.
# Without a Developer ID Application certificate and notarization, a
# cask install would leave OpenClicky.app Gatekeeper-quarantined — users
# would hit "OpenClicky can't be opened" on first launch, which is worse
# UX than the source-install path (git clone + make install) this
# formula is intended to replace.
#
# To activate this formula, complete steps 1-4 in docs/plan/release-setup.md
# (Apple Developer Program enrolment → Developer ID cert → 5 GH secrets →
# seed the tap repo). The release workflow will then populate version and
# sha256 automatically on each tag push.

cask "openclicky" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/kagantemizkan/openclicky/releases/download/v#{version}/OpenClicky-#{version}-arm64.dmg"
  name "OpenClicky"
  desc "Friendly, screen-aware Claude Code companion for macOS"
  homepage "https://github.com/kagantemizkan/openclicky"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "OpenClicky.app"

  zap trash: [
    "~/Library/Application Support/OpenClicky",
    "~/Library/Preferences/com.kagantemizkan.openclicky.plist",
    "~/Library/Caches/com.kagantemizkan.openclicky",
    "~/Library/Logs/com.kagantemizkan.openclicky",
  ]
end
