#!/bin/bash
#
# Release script: build app bundle, sign, notarize, publish
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.0.0
#
# Prerequisites:
#   - Xcode with Developer ID certificate
#   - Notarization credentials stored in keychain:
#     xcrun notarytool store-credentials "Ampere"
#   - GitHub CLI (gh) authenticated
#   - .project.env in the same directory
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$REPO_DIR/.project.env"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.0.0"
    exit 1
fi

SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "$TEAM_ID" | head -1 | sed 's/.*"\(.*\)"/\1/')"
BUILD_DIR="/tmp/${SCHEME}Build"
APP_DIR="$BUILD_DIR/$SCHEME.app"
DMG_PATH="/tmp/${SCHEME}.dmg"

cd "$REPO_DIR"

echo "==> Verifying clean working tree..."
if ! git diff --quiet HEAD; then
    echo "ERROR: uncommitted changes — commit or stash before releasing"
    exit 1
fi

echo "==> Running tests..."
swift test

echo "==> Tagging v$VERSION..."
git tag -f "v$VERSION"

echo "==> Building Release..."
cd "$REPO_DIR"
swift build -c release 2>&1

echo "==> Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binaries
cp "$REPO_DIR/.build/release/Ampere" "$APP_DIR/Contents/MacOS/Ampere"
cp "$REPO_DIR/.build/release/SMCWriter" "$APP_DIR/Contents/MacOS/SMCWriter"

# Write version file, copy icon, and compile asset catalog
echo "$VERSION" > "$APP_DIR/Contents/Resources/version.txt"
cp "$REPO_DIR/Ampere.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
xcrun actool "$REPO_DIR/Assets.xcassets" \
    --compile "$APP_DIR/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist /dev/null > /dev/null

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Ampere</string>
    <key>CFBundleIdentifier</key>
    <string>com.az-code-lab.ampere</string>
    <key>CFBundleName</key>
    <string>Ampere</string>
    <key>CFBundleDisplayName</key>
    <string>Ampere</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Signing with hardened runtime..."
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR/Contents/MacOS/SMCWriter"
codesign --force --timestamp --options runtime \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"

echo "==> Verifying signature..."
codesign -dvv "$APP_DIR" 2>&1 | grep -E "Authority|Timestamp"

echo "==> Creating zip for notarization..."
cd "$BUILD_DIR"
rm -f "$SCHEME.zip"
ditto -c -k --keepParent "$SCHEME.app" "$SCHEME.zip"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$SCHEME.zip" \
    --keychain-profile "$SCHEME" \
    --wait

echo "==> Stapling app ticket..."
xcrun stapler staple "$APP_DIR"

echo "==> Notarizing SMCWriter standalone (for /usr/local/bin install)..."
rm -f "$BUILD_DIR/SMCWriter.zip"
ditto -c -k --keepParent "$APP_DIR/Contents/MacOS/SMCWriter" "$BUILD_DIR/SMCWriter.zip"
xcrun notarytool submit "$BUILD_DIR/SMCWriter.zip" \
    --keychain-profile "$SCHEME" \
    --wait
rm -f "$BUILD_DIR/SMCWriter.zip"

echo "==> Creating DMG..."
rm -rf "/tmp/${SCHEME}DMG" "$DMG_PATH"
mkdir -p "/tmp/${SCHEME}DMG"
cp -R "$APP_DIR" "/tmp/${SCHEME}DMG/"
ln -s /Applications "/tmp/${SCHEME}DMG/Applications"
hdiutil create -volname "$SCHEME" \
    -srcfolder "/tmp/${SCHEME}DMG" \
    -ov -format UDZO "$DMG_PATH"

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "==> DMG SHA256: $SHA256"

echo "==> Pushing tag..."
cd "$REPO_DIR"
git push origin "v$VERSION" -f

echo "==> Updating GitHub release v$VERSION..."
gh release delete "v$VERSION" --repo "$GITHUB_REPO" --yes 2>/dev/null || true
gh release create "v$VERSION" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "v$VERSION" \
    --notes "## $SCHEME v$VERSION

Signed and notarized.

**SHA256:** \`$SHA256\`"

echo "==> Updating Homebrew cask..."
TAP_DIR=$(mktemp -d)
gh repo clone "$HOMEBREW_TAP_REPO" "$TAP_DIR" -- -q
cd "$TAP_DIR"
sed -i '' "s/version \".*\"/version \"$VERSION\"/" "Casks/${CASK_NAME}.rb"
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA256\"/" "Casks/${CASK_NAME}.rb"
git add "Casks/${CASK_NAME}.rb"
git commit -m "Update ${CASK_NAME} to v$VERSION"
git push
cd "$REPO_DIR"
rm -rf "$TAP_DIR"

echo "==> Updating local tap..."
cd "$(brew --repo az-code-lab/taps)" && git pull -q

echo ""
echo "==> Done! Released v$VERSION"
echo "    GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "    Install: brew tap az-code-lab/taps && brew install --cask ${CASK_NAME}"
