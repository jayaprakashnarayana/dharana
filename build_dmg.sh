#!/bin/bash
set -e

PROJECT_DIR="/Users/jnaguboina/Dharana"
BUILD_DIR="$PROJECT_DIR/build_temp"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="Dharana"
DMG_NAME="Dharana-Installer.dmg"
ZIP_NAME="Dharana-macOS.zip"

echo "🧘 Building $APP_NAME for macOS..."

cd "$PROJECT_DIR"

# 1. Compile latest Swift binary with optimization
echo "📦 Compiling Swift binary..."
swiftc -sdk $(xcrun --show-sdk-path --sdk macosx) -O main.swift -o "$PROJECT_DIR/Dharana"

# 2. Ensure App Bundle is up to date
echo "📁 Updating App Bundle and Resources..."
mkdir -p "$PROJECT_DIR/Dharana.app/Contents/MacOS"
mkdir -p "$PROJECT_DIR/Dharana.app/Contents/Resources"

cp "$PROJECT_DIR/Dharana" "$PROJECT_DIR/Dharana.app/Contents/MacOS/$APP_NAME"
chmod +x "$PROJECT_DIR/Dharana.app/Contents/MacOS/$APP_NAME"

cp "$PROJECT_DIR/Info.plist" "$PROJECT_DIR/Dharana.app/Contents/Info.plist"

if [ -f "$PROJECT_DIR/Dharana.icns" ]; then
    cp "$PROJECT_DIR/Dharana.icns" "$PROJECT_DIR/Dharana.app/Contents/Resources/AppIcon.icns"
    cp "$PROJECT_DIR/Dharana.icns" "$PROJECT_DIR/Dharana.app/Contents/Resources/Dharana.icns"
fi

# Refresh macOS bundle metadata
touch "$PROJECT_DIR/Dharana.app"

# 3. Prepare Staging directory for DMG
echo "💿 Preparing DMG packaging..."
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$DIST_DIR"

cp -R "$PROJECT_DIR/Dharana.app" "$BUILD_DIR/"

# Create symlink to /Applications for drag-and-drop install
ln -s /Applications "$BUILD_DIR/Applications"

# 4. Generate compressed DMG using hdiutil
echo "🚀 Creating $DMG_NAME..."
hdiutil create -volname "$APP_NAME Installer" \
               -srcfolder "$BUILD_DIR" \
               -ov \
               -format UDZO \
               "$DIST_DIR/$DMG_NAME"

# 5. Also create a portable .zip release
echo "📦 Creating $ZIP_NAME..."
cd "$BUILD_DIR"
zip -r -q "$DIST_DIR/$ZIP_NAME" "$APP_NAME.app"

# Clean up temporary build folder
rm -rf "$BUILD_DIR"

echo "✅ Build Complete!"
echo "📍 DMG Installer: $DIST_DIR/$DMG_NAME"
echo "📍 ZIP Archive:   $DIST_DIR/$ZIP_NAME"
