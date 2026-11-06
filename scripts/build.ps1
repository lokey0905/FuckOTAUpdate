[CmdletBinding()]
param(
    [string]$SdkRoot = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$JavaHome = '',
    [string]$Platform = 'android-36',
    [string]$BuildTools = '36.0.0'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $JavaHome) {
    $candidates = @($env:JAVA_HOME, 'C:\Program Files\Java\jdk-17', 'C:\Program Files\Java\jdk-21.0.12.1')
    $JavaHome = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'bin\javac.exe')) } | Select-Object -First 1
}
if (-not $JavaHome) { throw 'Specify -JavaHome with a JDK 17 or newer.' }
$javac = Join-Path $JavaHome 'bin\javac.exe'
$java = Join-Path $JavaHome 'bin\java.exe'
$androidJar = Join-Path $SdkRoot "platforms\$Platform\android.jar"
$d8Jar = Join-Path $SdkRoot "build-tools\$BuildTools\lib\d8.jar"
foreach ($dependency in @($javac, $java, $androidJar, $d8Jar)) {
    if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) { throw "Missing dependency: $dependency" }
}

$buildDir = Join-Path $projectRoot ('.build\' + [Guid]::NewGuid().ToString('N'))
$classDir = Join-Path $buildDir 'classes'
$dexDir = Join-Path $buildDir 'dex'
$null = New-Item -ItemType Directory -Force -Path $classDir, $dexDir
$sources = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'helper\src') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName })
if (-not $sources.Count) { throw 'No helper Java sources found.' }
& $javac --release 8 -encoding UTF-8 -cp $androidJar -d $classDir @sources
if ($LASTEXITCODE -ne 0) { throw "javac failed: $LASTEXITCODE" }
$classFiles = @(Get-ChildItem -LiteralPath $classDir -Recurse -Filter '*.class' | ForEach-Object { $_.FullName })
& $java -cp $d8Jar com.android.tools.r8.D8 --min-api 26 --lib $androidJar --output $dexDir @classFiles
if ($LASTEXITCODE -ne 0) { throw "D8 failed: $LASTEXITCODE" }
Copy-Item -LiteralPath (Join-Path $dexDir 'classes.dex') -Destination (Join-Path $projectRoot 'helper\classes.dex') -Force

$moduleProps = @{}
Get-Content -LiteralPath (Join-Path $projectRoot 'module.prop') -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { $moduleProps[$matches[1]] = $matches[2] }
}
$update = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'update.json') -Encoding UTF8 | ConvertFrom-Json
if ($moduleProps.version -ne $update.version -or [int]$moduleProps.versionCode -ne [int]$update.versionCode) {
    throw 'module.prop and update.json versions do not match.'
}

$files = @('module.prop', 'common.sh', 'service.sh', 'cli.sh', 'action.sh', 'customize.sh', 'uninstall.sh', 'restore-worker.sh', 'helper/classes.dex', 'helper/README.md', 'README.md', 'CHANGELOG.md', 'update.json')
if (Test-Path -LiteralPath (Join-Path $projectRoot 'restore-boot.sh')) { $files += 'restore-boot.sh' }
$files += @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'profiles') -Filter '*.profile' | ForEach-Object { 'profiles/' + $_.Name })
$files += @('META-INF/com/google/android/update-binary', 'META-INF/com/google/android/updater-script')
foreach ($relative in $files) {
    $path = Join-Path $projectRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing distribution file: $relative" }
    if (-not $relative.EndsWith('.dex')) {
        $bytes = [IO.File]::ReadAllBytes($path)
        $content = [Text.Encoding]::UTF8.GetString($bytes)
        if ($content.Contains("`r")) { throw "Non-LF line endings: $relative" }
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
            throw "UTF-8 BOM is not allowed: $relative"
        }
    }
}

Add-Type -AssemblyName System.IO.Compression
$temporaryZip = Join-Path $buildDir 'FuckOTAUpdate.zip'
$stream = [IO.File]::Open($temporaryZip, [IO.FileMode]::CreateNew)
$archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    foreach ($relative in ($files | Sort-Object -Unique)) {
        $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2020, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $entry.ExternalAttributes = if ($relative.EndsWith('.sh') -or $relative.EndsWith('/update-binary')) { [int]0x81ED0000 } else { [int]0x81A40000 }
        $inputStream = [IO.File]::OpenRead((Join-Path $projectRoot $relative))
        $outputStream = $entry.Open()
        try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    }
} finally { $archive.Dispose(); $stream.Dispose() }
$zip = Join-Path $projectRoot 'FuckOTAUpdate.zip'
Copy-Item -LiteralPath $temporaryZip -Destination $zip -Force
[PSCustomObject]@{ Version = $moduleProps.version; VersionCode = $moduleProps.versionCode; Zip = $zip; Bytes = (Get-Item -LiteralPath $zip).Length; SHA256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash } | Format-List
