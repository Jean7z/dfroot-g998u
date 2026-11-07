#!/bin/sh
set -eu
cd "$(dirname "$0")"

./gradlew :app:assembleDebug --no-daemon
apk=$(find app/build/outputs/apk/debug -maxdepth 1 -type f -name '*.apk' -print -quit)
test -n "$apk" && test -s "$apk"
cp "$apk" ./dirtyfrag.apk
sha256sum ./dirtyfrag.apk
echo "Built debug APK: ./dirtyfrag.apk"
