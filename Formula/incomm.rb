# The release workflow (.github/workflows/release.yml) rewrites the tag and
# the revision below when a vX.Y tag is pushed; Homebrew refuses to build if
# the tag no longer points at that revision. Edit the rest by hand.
class Incomm < Formula
  desc "Line-anchored context threads for humans and AI agents"
  homepage "https://github.com/bitbyone/incomm"
  url "https://github.com/bitbyone/incomm.git",
      tag:      "v1.1",
      revision: "9105c9b27fa4e542262771447baffd225be759c9"
  license "MIT"
  head "https://github.com/bitbyone/incomm.git", branch: "main"

  depends_on "go" => :build

  def install
    cd "cli" do
      system "go", "build", *std_go_args(ldflags: "-X incomm/cmd.version=#{version}")
    end
  end

  test do
    assert_match "incomm #{version} ", shell_output("#{bin}/incomm version")
  end
end
