#!/bin/bash
#
# Builds a signed, notarized .dmg for VALHost, so other users can install the
# app with a simple drag-to-Applications step -- no Terminal, no Gatekeeper
# warnings.
#
# One-time prerequisites (same identities used for VALDriver -- see
# ../VALDriver/package.sh):
#   1. A "Developer ID Application" certificate in your keychain (signs the app).
#   2. Notarization credentials saved as a notarytool keychain profile, e.g.:
#        xcrun notarytool store-credentials VALNotary \
#            --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"
#
# Usage:
#   APP_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   TEAM_ID="TEAMID" \
#   NOTARY_PROFILE="VALNotary" \
#   ./package.sh
#
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.2}"
SCHEME="VALHost"
PROJECT="build_xcode/VALHost.xcodeproj"

APP_SIGN_ID="${APP_SIGN_ID:?Set APP_SIGN_ID to your 'Developer ID Application: NAME (TEAMID)'}"
TEAM_ID="${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

ARCHIVE="build/VALHost.xcarchive"
EXPORT_DIR="build/export"
EXPORT_OPTIONS="build/exportOptions.plist"
DMG_STAGE="build/dmgroot"
DMG_OUT="build/VALHost-${VERSION}.dmg"

# 1) Archive the Release configuration.
echo "==> [1/6] Archiving (team: $TEAM_ID)"
rm -rf "$ARCHIVE"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive

# 2) Export, re-signing with the Developer ID identity (hardened runtime +
#    secure timestamp; the disable-library-validation entitlement carries over
#    from the archived build settings so third-party plug-ins still load).
echo "==> [2/6] Exporting (Developer ID Application)"
rm -rf "$EXPORT_DIR"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>${APP_SIGN_ID}</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

APP="$EXPORT_DIR/VALHost.app"
codesign --verify --strict --verbose=2 "$APP"

# 3) Stage a drag-to-Applications disk image.
echo "==> [3/6] Staging .dmg contents"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

# 4) Build the disk image, then sign the .dmg container itself -- notarization
#    doesn't require this, but Gatekeeper's primary-signature check on a dmg
#    (see step 7) does; an unsigned dmg notarizes/staples fine yet still shows
#    "rejected / no usable signature" until it carries its own signature.
echo "==> [4/6] Building disk image"
rm -f "$DMG_OUT"
hdiutil create -volname "VALHost" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_OUT"
codesign --sign "$APP_SIGN_ID" --timestamp "$DMG_OUT"

# 5) + 6) Notarize and staple the .dmg itself (same pattern as VALDriver's .pkg:
#    one artifact, one submission, one staple).
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> [5/6] Notarizing (profile: $NOTARY_PROFILE) -- this can take a few minutes"
    xcrun notarytool submit "$DMG_OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> [6/6] Stapling notarization ticket"
    xcrun stapler staple "$DMG_OUT"
else
    echo "==> [5/6] NOTARY_PROFILE not set -> skipping notarization"
    echo "    The .dmg is signed but NOT notarized; Gatekeeper will block it on other Macs."
fi

echo ""
echo "==> Verifying"
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /' || true
spctl --assess --type open --context context:primary-signature -vv "$DMG_OUT" 2>&1 | sed 's/^/  /' || true

echo ""
echo "==> Done: $DMG_OUT"
