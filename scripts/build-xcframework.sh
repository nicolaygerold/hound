#!/bin/bash
set -e

VERSION="${1:-0.1.0}"
OUTPUT_DIR="release"
FRAMEWORK_NAME="CHound"

echo "Building XCFramework for version $VERSION..."

# Clean
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/macos-arm64" "$OUTPUT_DIR/macos-x86_64"

# Build for macOS arm64
echo "Building for macOS arm64..."
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos
cp zig-out/lib/libhound_c.a "$OUTPUT_DIR/macos-arm64/"

# Build for macOS x86_64
echo "Building for macOS x86_64..."
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos
cp zig-out/lib/libhound_c.a "$OUTPUT_DIR/macos-x86_64/"

# Create universal binary
echo "Creating universal binary..."
mkdir -p "$OUTPUT_DIR/macos-universal"
lipo -create \
    "$OUTPUT_DIR/macos-arm64/libhound_c.a" \
    "$OUTPUT_DIR/macos-x86_64/libhound_c.a" \
    -output "$OUTPUT_DIR/macos-universal/libhound_c.a"

# Create framework structure
FRAMEWORK_DIR="$OUTPUT_DIR/$FRAMEWORK_NAME.framework"
mkdir -p "$FRAMEWORK_DIR/Headers"
mkdir -p "$FRAMEWORK_DIR/Modules"

cp "$OUTPUT_DIR/macos-universal/libhound_c.a" "$FRAMEWORK_DIR/$FRAMEWORK_NAME"
cp include/hound.h "$FRAMEWORK_DIR/Headers/"

# Create module.modulemap
cat > "$FRAMEWORK_DIR/Modules/module.modulemap" << 'EOF'
framework module CHound {
    header "hound.h"
    export *
}
EOF

# Create Info.plist
cat > "$FRAMEWORK_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.nicolaygerold.CHound</string>
    <key>CFBundleName</key>
    <string>CHound</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
</dict>
</plist>
EOF

# Create XCFramework
echo "Creating XCFramework..."
rm -rf "$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"
xcodebuild -create-xcframework \
    -framework "$FRAMEWORK_DIR" \
    -output "$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"

# Create zip for release
echo "Creating release zip..."
cd "$OUTPUT_DIR"
zip -r "$FRAMEWORK_NAME.xcframework.zip" "$FRAMEWORK_NAME.xcframework"
CHECKSUM=$(swift package compute-checksum "$FRAMEWORK_NAME.xcframework.zip")
cd ..

echo ""
echo "✅ Build complete!"
echo "📦 XCFramework: $OUTPUT_DIR/$FRAMEWORK_NAME.xcframework.zip"
echo "🔑 Checksum: $CHECKSUM"
echo ""
echo "Add this to your Package.swift:"
echo ""
echo ".binaryTarget("
echo "    name: \"CHound\","
echo "    url: \"https://github.com/nicolaygerold/hound/releases/download/v$VERSION/$FRAMEWORK_NAME.xcframework.zip\","
echo "    checksum: \"$CHECKSUM\""
echo ")"
