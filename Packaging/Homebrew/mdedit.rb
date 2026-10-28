# Homebrew cask for MdEdit, in the msk-mdi/homebrew-tap repository as
# Casks/mdedit.rb:
#   brew install msk-mdi/tap/mdedit
# It installs the release's disk image into /Applications and links the
# mdedit command, a script that hands files to the sandboxed app. MdEdit is
# not notarized (that takes a paid Apple developer account), so the cask
# clears the quarantine flag the download leaves on the app, and it opens
# without Gatekeeper's prompt.
# For each release, set version and the DMG's sha256 (make-dmg.sh prints it).
cask "mdedit" do
  version "1.3.5"
  sha256 "a26865aa7898fb1d7c88e60c078d7d008ddecd5be94a1998f061e479a9ca6186"

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
  binary "#{appdir}/MdEdit.app/Contents/Helpers/mdedit"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/MdEdit.app"],
                          writable_paths: ["MdEdit.app"], writable_base: :appdir
  end

  zap trash: [
    "~/Library/Application Scripts/com.mdedit.MdEdit",
    "~/Library/Application Scripts/com.mdedit.MdEdit.QuickLook",
    "~/Library/Application Support/MdEdit",
    "~/Library/Caches/com.mdedit.MdEdit",
    "~/Library/Caches/MdEdit",
    "~/Library/Containers/com.mdedit.MdEdit",
    "~/Library/Containers/com.mdedit.MdEdit.QuickLook",
    "~/Library/HTTPStorages/com.mdedit.MdEdit",
    "~/Library/HTTPStorages/MdEdit",
    "~/Library/Preferences/com.mdedit.MdEdit.plist",
    "~/Library/Saved Application State/com.mdedit.MdEdit.savedState",
    "~/Library/WebKit/com.mdedit.MdEdit",
  ]
end
