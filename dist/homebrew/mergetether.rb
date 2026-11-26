cask "mergetether" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/vapor-pawelw/merge-tether/releases/download/v#{version}/MergeTether.dmg"
  name "MergeTether"
  desc "Menu-bar app that surfaces your GitLab to-do inbox via the glab CLI"
  homepage "https://github.com/vapor-pawelw/merge-tether"

  auto_updates true
  depends_on formula: "glab"
  depends_on macos: ">= :sonoma"

  app "MergeTether.app"

  preflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{staged_path}/MergeTether.app"]
  end

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/MergeTether.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Caches/com.vaporpw.MergeTether",
    "~/Library/Preferences/com.vaporpw.MergeTether.plist",
  ]
end
