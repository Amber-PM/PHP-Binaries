#builds the pinned ext-rtc for bin\php and enables it in php.ini
#run from the repository root after windows-compile-vs.ps1
$ErrorActionPreference = 'Stop'

$EXT_RTC_REPOSITORY = 'https://github.com/Amber-PM/ext-rtc.git'
$EXT_RTC_COMMIT = 'e57c53411d4145fd8ea1504ccb1e2af239a04c29'
$LIBDATACHANNEL_IDENTITY = 'libdatachannel/0.24.6;commit=6b1e2e620f1e37f0eafeee702eaea0043cb305fd;'

$root = $PSScriptRoot
$php = Join-Path $root 'bin\php'
$phpExe = Join-Path $php 'php.exe'
$phpIni = Join-Path $php 'php.ini'
$work = Join-Path $root 'rtc-build'
foreach ($path in @($phpExe, $phpIni)) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "missing $path" }
}

$env:PHPRC = ''
$env:PHP_INI_SCAN_DIR = ''
$phpVersion = (& $phpExe -n -r 'echo PHP_VERSION;').Trim()
if ($LASTEXITCODE -ne 0) { throw 'cannot run php.exe' }

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
$extRtc = Join-Path $work 'ext-rtc'
git clone -q $EXT_RTC_REPOSITORY $extRtc
if ($LASTEXITCODE -ne 0) { throw 'cannot clone ext-rtc' }
git -C $extRtc checkout -q --detach $EXT_RTC_COMMIT
if ($LASTEXITCODE -ne 0 -or (git -C $extRtc rev-parse HEAD).Trim() -ne $EXT_RTC_COMMIT) { throw 'ext-rtc revision mismatch' }

#ext-rtc builds the same php release with its pinned openssl and libdatachannel and checks the result itself
$build = Join-Path $extRtc ".build\windows\$phpVersion"
& (Join-Path $extRtc 'scripts\build-windows.ps1') -PhpVersion $phpVersion -BuildDirectory $build
if (!$?) { throw 'ext-rtc build failed' }

$release = Join-Path $build 'source\php-src\x64\Release_TS'
$modules = @(Get-ChildItem -LiteralPath $release -Filter 'php_rtc.dll' -File -Recurse)
if ($modules.Count -ne 1) { throw "expected one php_rtc.dll and found $($modules.Count)" }
$backend = Join-Path $release 'datachannel.dll'
if (!(Test-Path -LiteralPath $backend -PathType Leaf)) { throw 'missing datachannel.dll' }
Copy-Item -Force $modules[0].FullName (Join-Path $php 'ext\php_rtc.dll')
#datachannel.dll resolves the openssl dlls of php.exe from the same directory
Copy-Item -Force $backend (Join-Path $php 'datachannel.dll')

$lines = @(Get-Content -LiteralPath $phpIni | Where-Object { $_ -notmatch '^\s*;?\s*extension\s*=\s*(php_)?(web)?rtc(\.dll)?\s*$' })
$lines += ''
$lines += ';NetherNet transport for Minecraft 26.60 and later'
$lines += 'extension=php_rtc.dll'
[IO.File]::WriteAllLines($phpIni, [string[]]$lines, [Text.UTF8Encoding]::new($false))

$licenses = Join-Path $php 'licenses\ext-rtc'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item -Force (Join-Path $extRtc 'LICENSE') $licenses
Copy-Item -Force (Join-Path $extRtc 'third-party\NOTICES.md') $licenses
Copy-Item -Force (Join-Path $extRtc 'third-party\licenses\*.txt') $licenses

#php.ini uses a relative extension_dir so checks run from bin\php
Push-Location $php
try {
    $info = & $phpExe -c $phpIni --ri rtc 2>&1
    if ($LASTEXITCODE -ne 0 -or ($info -join ' ') -match '(?i)PHP Startup|Unable to load dynamic library|warning') { throw "php_rtc.dll does not load cleanly`n$($info -join "`n")" }
    $identity = (@($info | Select-String 'Loaded libdatachannel identity => (.*)').Matches | Select-Object -First 1).Groups[1].Value
    if (!$identity.StartsWith($LIBDATACHANNEL_IDENTITY)) { throw "wrong libdatachannel loaded $identity" }
    #native argument quoting differs between powershell versions so the php code uses single quotes only
    $check = & $phpExe -c $phpIni -r 'if(!extension_loaded(''rtc'') || extension_loaded(''webrtc'') || \amber\rtc\RtcRuntime::getApiVersion() !== 1){echo ''ext-rtc is not usable''; exit(1);} if(OPENSSL_VERSION_NUMBER < 0x30500000){echo OPENSSL_VERSION_TEXT, '' predates openssl 3.5''; exit(1);} echo ''ext-rtc '', phpversion(''rtc''), '' with '', OPENSSL_VERSION_TEXT;' 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($check -join "`n") }
    Write-Output $check
} finally {
    Pop-Location
}

Remove-Item -Recurse -Force $work
Write-Output "ext-rtc installed into $php"
