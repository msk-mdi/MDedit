# Homebrew cask for MdEdit, in the msk-mdi/homebrew-tap repository as
# Casks/mdedit.rb:
#   brew install msk-mdi/tap/mdedit
# It installs the release's disk image into /Applications and links the
# mdedit command. MdEdit is not notarized (that takes a paid Apple developer
# account), so the cask clears the quarantine flag the download leaves on the
# app, and it opens without Gatekeeper's prompt.
# For each release, set version and the DMG's sha256 (make-dmg.sh prints it).
cask "mdedit" do
  version "0.9.1"
  sha256 "98a2d6e354dee5b394eb257c002f70e18c5a3b9a6662a482d199f674112c7399"

  url "https://github.com/msk-mdi/MDedit/releases/download/v#{version}/MdEdit-#{version}.dmg"
  name "MdEdit"
  desc "Native in-place WYSIWYG markdown editor"
  homepage "https://github.com/msk-mdi/MDedit"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "MdEdit.app"
  binary "#{appdir}/MdEdit.app/Contents/MacOS/MdEdit", target: "mdedit"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/MdEdit.app"],
                          writable_paths: ["MdEdit.app"], writable_base: :appdir
  end

  zap trash: [
    "~/Library/Application Support/MdEdit",
    "~/Library/Preferences/com.mdedit.MdEdit.plist",
    "~/Library/Saved Application State/com.mdedit.MdEdit.savedState",
  ]
end
