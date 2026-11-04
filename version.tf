# The release tag of this module, sent to Starfolk in the hand-back so it can
# tell which release each account was set up with. A module can't read its own
# git ref, so this is set by hand: bump it in the release PR, then tag that
# commit with the same value. The release workflow refuses a tag that doesn't
# match.
locals {
  module_version = "v1.3.0"
}
