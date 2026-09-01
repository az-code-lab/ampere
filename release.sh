#!/bin/bash
#
# Release script: build app bundle, sign, notarize, publish
#
# Usage: ./release.sh <version> [--force]
#   e.g. ./release.sh 1.0.0
#   --force allows re-releasing a version whose tag already exists
#   (replaces the tag, the GitHub release, and the cask entry)
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
FORCE="${2:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version> [--force]"
    echo "Example: ./release.sh 1.0.0"
    exit 1
fi

# Plain dotted digits only. A "v" prefix would ship a cask version that
# parseDottedVersion rejects on every client — the in-app update would
# silently never be offered for that release.
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "ERROR: version must be plain dotted digits (e.g. 1.2.3), got: $VERSION"
    exit 1
fi

# Reusing a version number silently replaces the old tag, GitHub release,
# and cask entry (tag -f / push -f / gh release delete below). Make that
# an explicit choice rather than a typo's outcome.
if git rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null && [ "$FORCE" != "--force" ]; then
    echo "ERROR: tag v$VERSION already exists — releasing would replace it"
    echo "       To re-release deliberately: ./release.sh $VERSION --force"
    exit 1
fi

# Match on the certificate NAME, not just the team: an "Apple Development"
# certificate carries the team id too, and signing a release with it produces
# a bundle Gatekeeper rejects on every machine that did not build it. Matching
# the team alone left that to whatever `find-identity` happened to list first.
#
# `|| true`, with the emptiness test below as the only error path: a grep that
# matches nothing exits 1, `set -o pipefail` fails the whole substitution on
# it, and `set -e` ends the script right here — swallowing the one message
# that names the certificate that is missing.
SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "$TEAM_ID" \
    | sed -n '1s/.*"\(.*\)"/\1/p' || true)"
if [ -z "$SIGN_IDENTITY" ]; then
    echo "ERROR: no \"Developer ID Application\" certificate for team $TEAM_ID in the keychain"
    echo "       Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    exit 1
fi
BUILD_DIR="/tmp/${SCHEME}Build"
APP_DIR="$BUILD_DIR/$SCHEME.app"
DMG_PATH="/tmp/${SCHEME}.dmg"

cd "$REPO_DIR"

echo "==> Verifying clean working tree..."
# git status --porcelain (unlike git diff HEAD) also catches untracked
# files: a forgotten `git add` would otherwise compile into the shipped
# binary while the pushed tag lacks the file, making the release
# irreproducible from source.
if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree not clean — commit, stash, or remove these before releasing:"
    git status --short
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

# The disk image gets the same treatment as the app it carries. The app's
# stapled ticket is what clears a first launch, so this is not what makes the
# download open — but an unsigned image reads as "no usable signature" to any
# assessment of the file itself, and `spctl -a -t open` is exactly what macOS
# runs when a quarantined image is opened.
echo "==> Signing DMG..."
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

echo "==> Notarizing DMG..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$SCHEME" \
    --wait

echo "==> Stapling DMG ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# AFTER the signing and stapling above, both of which rewrite the file: a hash
# taken any earlier is the hash of an image nobody will ever download, and
# `brew install` would refuse the real one as a checksum mismatch.
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
