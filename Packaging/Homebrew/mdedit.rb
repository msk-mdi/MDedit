# Homebrew formula for MdEdit: builds the app on the user's Mac, so it is not
# quarantined and opens without Gatekeeper's warning — no Apple Developer ID
# needed. It belongs in a tap: a repository named homebrew-tap under
# msk-mdi, as Formula/mdedit.rb. Then:
#   brew install msk-mdi/tap/mdedit        # the latest release
#   brew install --HEAD msk-mdi/tap/mdedit # main
# For each release, set url's version and sha256:
#   curl -sL https://github.com/msk-mdi/MDedit/archive/refs/tags/v<version>.tar.gz | shasum -a 256
class Mdedit < Formula
  desc "Native in-place WYSIWYG markdown editor"
  homepage "https://github.com/msk-mdi/MDedit"
  url "https://github.com/msk-mdi/MDedit/archive/refs/tags/v0.9.0.tar.gz"
  sha256 "REPLACE_WITH_THE_TARBALL_SHA256"
  license "Apache-2.0"
  head "https://github.com/msk-mdi/MDedit.git", branch: "main"

  # Swift 6.2 and the macOS 26 SDK, from Xcode 26 or its Command Line Tools.
  depends_on macos: :tahoe

  def install
    # Homebrew's sandbox and SwiftPM's cannot nest.
    ENV["MDEDIT_SWIFT_FLAGS"] = "--disable-sandbox"
    system "Scripts/make-app.sh", "release"
    prefix.install "build/MdEdit.app"
    # The command line renderer: mdedit --render notes.md
    bin.install_symlink prefix/"MdEdit.app/Contents/MacOS/MdEdit" => "mdedit"
  end

  def caveats
    <<~EOS
      MdEdit.app is in #{opt_prefix}. To have it in Applications, Spotlight and
      Launchpad, and as the app that opens markdown files:
        ln -sf #{opt_prefix}/MdEdit.app /Applications/MdEdit.app
        open /Applications/MdEdit.app
      The link follows upgrades.
    EOS
  end

  test do
    assert_match "Hi</h1>", pipe_output("#{bin}/mdedit --render", "# Hi\n")
  end
end
