#!/bin/bash
set -e

# ==============================================================================
# u-NTFS Release Packaging Script
# Builds the macOS Application Bundle and packages it into a distributable .dmg
# ==============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
RELEASE_DIR="${BUILD_DIR}/Release"
APP_NAME="u-NTFS"
APP_BUNDLE="${RELEASE_DIR}/${APP_NAME}.app"
DIST_DIR="${PROJECT_DIR}/dist"
VERSION="0.3.5"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-v${VERSION}.zip"

echo "==> 🚀 Cleaning previous builds..."
rm -rf "${BUILD_DIR}"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

echo "==> 🔨 Building Release target with xcodebuild..."
cd "${PROJECT_DIR}"
xcodebuild -scheme "NTFS-Project" \
    -configuration Release \
    -destination "platform=macOS" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    SYMROOT="${BUILD_DIR}" \
    build | grep -E "(BUILD SUCCEEDED|error:)" || true

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "❌ Build failed! App bundle not found at: ${APP_BUNDLE}"
    exit 1
fi

echo "==> ✅ Release build successful: ${APP_BUNDLE}"

# Create staging directory for DMG
DMG_STAGING="${BUILD_DIR}/dmg_staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"

echo "==> 📦 Preparing DMG contents..."
cp -R "${APP_BUNDLE}" "${DMG_STAGING}/"
# Symlink to /Applications for standard drag-and-drop installer experience
ln -s /Applications "${DMG_STAGING}/Applications"

echo "==> 📀 Creating Disk Image (.dmg)..."
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "${DMG_PATH}"

echo "==> 🗜 Creating standalone .zip archive..."
cd "${RELEASE_DIR}"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${ZIP_PATH}"

echo ""
echo "=============================================================================="
echo "🎉 Packaging Complete!"
echo "=============================================================================="
echo "📁 Distribution files created in: ${DIST_DIR}"
echo "  1. DMG Installer : ${DMG_PATH}"
echo "  2. ZIP Archive   : ${ZIP_PATH}"
echo "  3. App Bundle    : ${APP_BUNDLE}"
echo "=============================================================================="
