#!/usr/bin/env bash
# builds the pinned ext-rtc into bin/php7 and enables it in php.ini
# run from the repository root after compile.sh
set -euo pipefail

EXT_RTC_REPOSITORY="https://github.com/Amber-PM/ext-rtc.git"
EXT_RTC_COMMIT="e57c53411d4145fd8ea1504ccb1e2af239a04c29"
LIBDATACHANNEL_IDENTITY="libdatachannel/0.24.6;commit=6b1e2e620f1e37f0eafeee702eaea0043cb305fd;"

root="$(pwd -P)"
prefix="$root/bin/php7"
ini="$prefix/bin/php.ini"
work="$root/rtc-build"
test -x "$prefix/bin/php"
test -x "$prefix/bin/phpize"
test -x "$prefix/bin/php-config"
test -f "$ini"
command -v patchelf >/dev/null

unset PHPRC PHP_INI_SCAN_DIR
run_php(){ LD_LIBRARY_PATH="$prefix/lib" "$prefix/bin/php" "$@"; }
php(){ run_php -n "$@"; }
php_version="$(php -r 'echo PHP_VERSION;')"
php -r 'if(!PHP_ZTS){fwrite(STDERR, "ext-rtc needs ZTS\n"); exit(1);}'
rm -rf "$work"
mkdir -p "$work/php-src" "$work/php-dev/bin" "$work/php-dev/lib/php"

# the release keeps no php headers so configure the same php version for them
curl -fsSL "https://www.php.net/distributions/php-$php_version.tar.xz" | tar -xJ --strip-components=1 -C "$work/php-src"
(cd "$work/php-src" && ./configure --enable-zts --disable-all --disable-cgi --without-pear --prefix="$work/php-dev" > "$work/php-headers.log")
printf '#!/bin/sh\nLD_LIBRARY_PATH="%s" exec "%s" "$@"\n' "$prefix/lib" "$prefix/bin/php" > "$work/php-dev/bin/php"
chmod +x "$work/php-dev/bin/php"
mkdir -p "$work/php-dev/include"
ln -sfn "$work/php-src" "$work/php-dev/include/php"
ln -sfn "$prefix/lib/php/build" "$work/php-dev/lib/php/build"
old_prefix="$("$prefix/bin/php-config" --prefix)"
sed "s|$old_prefix|$work/php-dev|g" "$prefix/bin/php-config" > "$work/php-dev/bin/php-config"
sed "s|$old_prefix|$work/php-dev|g" "$prefix/bin/phpize" > "$work/php-dev/bin/phpize"
chmod +x "$work/php-dev/bin/php-config" "$work/php-dev/bin/phpize"

git clone -q "$EXT_RTC_REPOSITORY" "$work/ext-rtc"
git -C "$work/ext-rtc" checkout -q --detach "$EXT_RTC_COMMIT"
test "$(git -C "$work/ext-rtc" rev-parse HEAD)" = "$EXT_RTC_COMMIT"
# ext-rtc builds and verifies its pinned openssl and libdatachannel itself
bash "$work/ext-rtc/scripts/build-openssl.sh"
PKG_CONFIG_PATH="$work/ext-rtc/.build/openssl/lib/pkgconfig" bash "$work/ext-rtc/scripts/build-linux.sh" \
	--php "$work/php-dev/bin/php" --php-config "$work/php-dev/bin/php-config" --phpize "$work/php-dev/bin/phpize" \
	--build-dir "$work/ext-rtc/.build/rtc"
build="$work/ext-rtc/.build/rtc"

extension_dir="$(find "$prefix/lib/php/extensions" -mindepth 1 -maxdepth 1 -type d -name 'no-debug-zts-*' -print -quit)"
test -n "$extension_dir"
cp "$build/extension/modules/rtc.so" "$extension_dir/rtc.so"
cp -a "$build/install/lib/"libdatachannel.so* "$prefix/lib/"
# the extension sits three levels below lib and must resolve libdatachannel there
patchelf --set-rpath '$ORIGIN/../../..' "$extension_dir/rtc.so"
while IFS= read -r -d '' library; do
	patchelf --set-rpath '$ORIGIN' "$library"
done < <(find "$prefix/lib" -maxdepth 1 -type f -name 'libdatachannel.so*' -print0)

sed -i -E '/^[[:space:]]*;?[[:space:]]*extension[[:space:]]*=[[:space:]]*(php_)?(web)?rtc(\.so)?[[:space:]]*$/d' "$ini"
printf '\n;NetherNet transport for Minecraft 26.60 and later\nextension=rtc.so\n' >> "$ini"

mkdir -p "$prefix/share/licenses/ext-rtc"
cp "$work/ext-rtc/LICENSE" "$prefix/share/licenses/ext-rtc/LICENSE"
cp "$work/ext-rtc/third-party/NOTICES.md" "$prefix/share/licenses/ext-rtc/NOTICES.md"
cp "$work/ext-rtc/third-party/licenses/"*.txt "$prefix/share/licenses/ext-rtc/"

cd "$root"
identity="$(run_php -c "$ini" --ri rtc | awk -F ' => ' '$1 == "Loaded libdatachannel identity" {print $2}')"
case "$identity" in
	"$LIBDATACHANNEL_IDENTITY"*) ;;
	*) echo "wrong libdatachannel loaded: $identity" >&2; exit 1 ;;
esac
run_php -c "$ini" -r '
if(!extension_loaded("rtc") || extension_loaded("webrtc") || \amber\rtc\RtcRuntime::getApiVersion() !== 1){fwrite(STDERR, "ext-rtc is not usable\n"); exit(1);}
if(OPENSSL_VERSION_NUMBER < 0x30500000){fwrite(STDERR, OPENSSL_VERSION_TEXT . " predates the openssl 3.5 build of libdatachannel\n"); exit(1);}
echo "ext-rtc ", phpversion("rtc"), " with ", OPENSSL_VERSION_TEXT, "\n";
'
rm -rf "$work"
echo "ext-rtc installed into $prefix"
