#!/bin/bash
set -e

echo "Building Wanderer.swiftpm..."

cd "$(dirname "$0")"
cd Wanderer.swiftpm

xcodebuild -scheme Wanderer -destination 'platform=macOS' -workspace .

echo "Build successful!"
