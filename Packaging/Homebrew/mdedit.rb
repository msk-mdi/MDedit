# Homebrew cask for MdEdit. It belongs in a tap (a repository named
# homebrew-<tap>, e.g. msk-mdi/homebrew-tap, under Casks/), and needs the
# version and sha256 of each release's DMG: Scripts/make-dmg.sh prints it.
#   brew install --cask msk-mdi/tap/mdedit
cask "mdedit" do
  version "0.9.0"
  sha256 :no_check # replace with the release DMG's checksum

  url "https://github.com/msk-mdi/MDedit/releases/download/v#{version}/MdEdit-#{version}.dmg"
  name "MdEdit"
  desc "Native in-place WYSIWYG markdown editor"
  homepage "https://github.com/msk-mdi/MDedit"

  depends_on macos: ">= :tahoe"

  app "MdEdit.app"

  zap trash: [
    "~/Library/Application Support/MdEdit",
    "~/Library/Preferences/com.mdedit.MdEdit.plist",
    "~/Library/Saved Application State/com.mdedit.MdEdit.savedState",
  ]
end
