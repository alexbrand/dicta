#!/bin/bash

set -e

# Configuration
APP_NAME="dicta"
DMG_NAME="dicta"
BUILD_DIR="build"
DMG_DIR="dmg_temp"
BACKGROUND_IMAGE=""  # Optional: path to background image

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building ${APP_NAME} for distribution...${NC}"

# Clean previous builds
rm -rf "${BUILD_DIR}"
rm -rf "${DMG_DIR}"
rm -f "${DMG_NAME}.dmg"

# Build the app for release
echo -e "${YELLOW}Building app...${NC}"
xcodebuild -project "${APP_NAME}.xcodeproj" \
           -scheme "${APP_NAME}" \
           -configuration Release \
           -derivedDataPath "${BUILD_DIR}" \
           -archivePath "${BUILD_DIR}/${APP_NAME}.xcarchive" \
           archive

# Export the app
echo -e "${YELLOW}Exporting app...${NC}"
xcodebuild -exportArchive \
           -archivePath "${BUILD_DIR}/${APP_NAME}.xcarchive" \
           -exportPath "${BUILD_DIR}/export" \
           -exportOptionsPlist export_options.plist

# Create temporary DMG directory
mkdir -p "${DMG_DIR}"

# Copy app to DMG directory
cp -R "${BUILD_DIR}/export/${APP_NAME}.app" "${DMG_DIR}/"

# Create Applications symlink
ln -s /Applications "${DMG_DIR}/Applications"

# Add background image if specified
if [ ! -z "$BACKGROUND_IMAGE" ] && [ -f "$BACKGROUND_IMAGE" ]; then
    mkdir -p "${DMG_DIR}/.background"
    cp "$BACKGROUND_IMAGE" "${DMG_DIR}/.background/"
fi

# Calculate DMG size (app size + 50MB buffer)
APP_SIZE=$(du -sm "${DMG_DIR}" | cut -f1)
DMG_SIZE=$((APP_SIZE + 50))

echo -e "${YELLOW}Creating DMG...${NC}"

# Create the DMG
hdiutil create -srcfolder "${DMG_DIR}" \
               -volname "${APP_NAME}" \
               -fs HFS+ \
               -fsargs "-c c=64,a=16,e=16" \
               -format UDRW \
               -size ${DMG_SIZE}m \
               "${DMG_NAME}_temp.dmg"

# Mount the DMG
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "${DMG_NAME}_temp.dmg" | egrep '^/dev/' | sed 1q | awk '{print $1}')
MOUNT_POINT="/Volumes/${APP_NAME}"

# Wait for mount
sleep 2

# Set DMG window properties using AppleScript
osascript <<EOF
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 900, 400}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "${APP_NAME}.app" of container window to {150, 200}
        set position of item "Applications" of container window to {350, 200}
        close
        open
        update without registering applications
        delay 5
        close
    end tell
end tell
EOF

# Unmount the DMG
hdiutil detach "${DEVICE}"

# Convert to compressed, read-only DMG
echo -e "${YELLOW}Compressing DMG...${NC}"
hdiutil convert "${DMG_NAME}_temp.dmg" \
                -format UDZO \
                -imagekey zlib-level=9 \
                -o "${DMG_NAME}.dmg"

# Clean up
rm -f "${DMG_NAME}_temp.dmg"
rm -rf "${DMG_DIR}"
rm -rf "${BUILD_DIR}"

echo -e "${GREEN}DMG created successfully: ${DMG_NAME}.dmg${NC}"
echo -e "${GREEN}Ready for distribution!${NC}"