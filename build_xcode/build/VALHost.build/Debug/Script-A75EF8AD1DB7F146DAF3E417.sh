#!/bin/sh
set -e
if test "$CONFIGURATION" = "Debug"; then :
  cd /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode
  /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode/juce/tools/extras/Build/juceaide/juceaide_artefacts/Custom/juceaide pkginfo App /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode/VALHost_artefacts/JuceLibraryCode/VALHost/PkgInfo
fi
if test "$CONFIGURATION" = "Release"; then :
  cd /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode
  /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode/juce/tools/extras/Build/juceaide/juceaide_artefacts/Custom/juceaide pkginfo App /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode/VALHost_artefacts/JuceLibraryCode/VALHost/PkgInfo
fi
if test "$CONFIGURATION" = "MinSizeRel"; then :
  cd /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode
  /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode/juce/tools/extras/Build/juceaide/juceaide_artefacts/Custom/juceaide pkginfo App /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode/VALHost_artefacts/JuceLibraryCode/VALHost/PkgInfo
fi
if test "$CONFIGURATION" = "RelWithDebInfo"; then :
  cd /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode
  /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode/juce/tools/extras/Build/juceaide/juceaide_artefacts/Custom/juceaide pkginfo App /Volumes/X9-Mac-mini/src/swift/Swift_2026/VALHost/build_xcode/VALHost_artefacts/JuceLibraryCode/VALHost/PkgInfo
fi

