#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product ICR6Editor
binary="$(swift build -c release --show-bin-path)/ICR6Editor"
library="$(otool -L "$binary" | awk '/libusb-1\.0\.0\.dylib/ {print $1; exit}')"
prefix="$(pkg-config --variable=prefix libusb-1.0)"
minimum="$(vtool -show-build "$library" | awk '/minos/ {print $2; exit}')"
app="$PWD/IC-R6 メモリーエディタ.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources"
cp "$binary" "$contents/MacOS/ICR6Editor"
cp -L "$library" "$contents/Frameworks/libusb-1.0.0.dylib"
cp "$prefix/COPYING" "$contents/Resources/libusb-COPYING.txt"
cp LICENSE "$contents/Resources/LICENSE.txt"
cp Sources/R6Core/Resources/{JapanAirports,JapanRailways}.json "$contents/Resources/"
cp Assets/AppIcon.icns "$contents/Resources/"
chmod u+w "$contents/Frameworks/libusb-1.0.0.dylib"

install_name_tool -id '@executable_path/../Frameworks/libusb-1.0.0.dylib' \
    "$contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -change "$library" '@executable_path/../Frameworks/libusb-1.0.0.dylib' \
    "$contents/MacOS/ICR6Editor"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>IC-R6 メモリーエディタ</string>
    <key>CFBundleName</key><string>IC-R6 メモリーエディタ</string>
    <key>CFBundleIdentifier</key><string>local.icr6.memory-editor</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleExecutable</key><string>ICR6Editor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>IC-R6 メモリーファイル</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.icom.clone-format</string></array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.icom.clone-format</string>
            <key>UTTypeDescription</key><string>IC-R6 メモリーファイル</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key><array><string>icf</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
if [[ "${minimum%%.*}" -gt 14 ]]; then
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum" "$contents/Info.plist"
fi

codesign --force --sign - "$contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
