#!/bin/sh
# Builds out/pa2q-manager.apk with nothing but the Android SDK: no Gradle, no
# libraries. Needs platform android-35, build-tools 35.0.0, clang and a JDK.
set -eu
cd "$(dirname "$(readlink -f "$0")")"
SDK=${ANDROID_HOME:-$HOME/Android/Sdk}
BT=$SDK/build-tools/35.0.0
JAR=$SDK/platforms/android-35/android.jar
KEY=${PA2Q_KEYSTORE:-$HOME/.android/debug.keystore}	# keep the same key: Android refuses updates from another

sh test-pa2qctl.sh >/dev/null || { echo "pa2qctl tests failed: sh test-pa2qctl.sh" >&2; exit 1; }

rm -rf out
mkdir -p out/gen out/classes out/assets
cp assets/pa2qctl.sh out/assets/
clang --target=aarch64-linux-gnu -static -nostdlib -ffreestanding -fno-stack-protector -fuse-ld=lld -O2 \
	../recovery/loopcfg.c -o out/assets/loopcfg

"$BT/aapt2" compile --dir res -o out/res.zip
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml -A out/assets \
	--min-sdk-version 34 --target-sdk-version 34 \
	--java out/gen -o out/unsigned.apk out/res.zip

javac --release 17 -Xlint:-options -cp "$JAR" -d out/classes \
	$(find out/gen src -name '*.java')
"$BT/d8" --release --min-api 34 --lib "$JAR" --output out $(find out/classes -name '*.class')
(cd out && zip -q -j unsigned.apk classes.dex)

"$BT/zipalign" -f -p 4 out/unsigned.apk out/aligned.apk
"$BT/apksigner" sign --ks "$KEY" --ks-pass pass:android --key-pass pass:android \
	--out out/pa2q-manager.apk out/aligned.apk
"$BT/apksigner" verify out/pa2q-manager.apk
ls -l out/pa2q-manager.apk
