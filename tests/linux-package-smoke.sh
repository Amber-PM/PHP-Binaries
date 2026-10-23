#!/usr/bin/env bash
set -euo pipefail

# Run from the artifact root, which contains bin/php7/.
cd "$(dirname "$0")/.."
php="bin/php7/bin/php"
ini="bin/php7/bin/php.ini"
test -x "$php"
test -f "$ini"

extension_dir="$(find bin/php7/lib/php/extensions -mindepth 1 -maxdepth 1 -type d -name 'no-debug-zts-*' -print -quit)"
test -n "$extension_dir"
configured="$(sed -n 's/^extension_dir=//p' "$ini")"
if [[ "$configured" != "./$extension_dir" ]]; then
    echo "Wrong extension_dir: $configured (expected ./$extension_dir)" >&2
    exit 1
fi

export LD_LIBRARY_PATH="$PWD/bin/php7/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PHP_INI_SCAN_DIR=""
version_output="$("$php" -c "$ini" -v 2>&1)"
module_output="$("$php" -c "$ini" -m 2>&1)"
if grep -Eiq '(^|[[:space:]])(warning|fatal error|parse error):' <<<"$version_output"$'\n'"$module_output"; then
    echo "$version_output" >&2
    echo "$module_output" >&2
    exit 1
fi

"$php" -c "$ini" -r '
    if (!PHP_ZTS) { fwrite(STDERR, "ZTS is missing\n"); exit(1); }
    foreach (["pmmpthread", "leveldb", "crypto", "encoding", "libdeflate", "chunkutils2", "igbinary", "morton", "yaml", "Zend OPcache", "ext-quiche"] as $extension) {
        if (!extension_loaded($extension)) {
            fwrite(STDERR, "Missing PHP extension: " . $extension . "\n");
            exit(1);
        }
    }
    echo PHP_VERSION . " ZTS and required extensions: PASS\n";
'
echo "Linux package smoke test: PASS"