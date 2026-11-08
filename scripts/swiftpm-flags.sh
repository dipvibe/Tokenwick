# Shared SwiftPM flags. Source this file; don't run it.
#
# - The native build system works with only the Command Line Tools installed
#   (the newer default one can fail with "Unknown error parsing property list").
# - With only the Command Line Tools, Swift Testing lives in a framework folder
#   SwiftPM doesn't search, so pass it explicitly.

SWIFTPM_FLAGS=(--build-system native)

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  FW="$DEV_DIR/Library/Developer/Frameworks"
  SWIFTPM_TEST_FLAGS=(-Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW")
else
  SWIFTPM_TEST_FLAGS=()
fi
