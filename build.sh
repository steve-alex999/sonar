#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app=build/Sonar.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/ModuleCache
swiftc -O -module-cache-path build/ModuleCache -parse-as-library Sonar.swift -o "$app/Contents/MacOS/Sonar" -framework SwiftUI -framework AVFoundation -framework ApplicationServices
cp Info.plist "$app/Contents/Info.plist"
cp SonarIcon.icns "$app/Contents/Resources/SonarIcon.icns"
xattr -cr "$app"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built build/Sonar.app"
