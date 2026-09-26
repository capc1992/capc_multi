param([string]$Version)

$ErrorActionPreference = 'Stop'
$capcProject = Split-Path -Parent $PSScriptRoot
$capcRelease = Join-Path $capcProject 'build\windows\x64\runner\Release'
$capcExecutable = Join-Path $capcRelease 'capc_multi.exe'
if (-not (Test-Path -LiteralPath $capcExecutable)) {
    throw 'Primero ejecuta flutter build windows --release.'
}
$capcPubspec = Get-Content -LiteralPath (Join-Path $capcProject 'pubspec.yaml') -Raw
$capcVersionMatch = [regex]::Match($capcPubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $capcVersionMatch.Success) { throw 'No se pudo leer la versión en pubspec.yaml.' }
$capcSourceVersion = $capcVersionMatch.Groups[1].Value
$capcBuildVersion = $capcSourceVersion + '+' + $capcVersionMatch.Groups[2].Value
if (-not $Version) { $Version = $capcSourceVersion }
if ($Version -ne $capcSourceVersion) { throw 'La versión del paquete debe coincidir con pubspec.yaml.' }
if ((Get-Item -LiteralPath $capcExecutable).VersionInfo.ProductVersion -ne $capcBuildVersion) {
    throw 'El ejecutable pertenece a otra versión. Ejecuta flutter build windows --release.'
}
$capcRequired = @(
    'flutter_windows.dll', 'sqlite3.dll', 'pdfium.dll',
    'printing_plugin.dll', 'file_selector_windows_plugin.dll',
    'data\app.so', 'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin'
)
foreach ($capcRelative in $capcRequired) {
    if (-not (Test-Path -LiteralPath (Join-Path $capcRelease $capcRelative) -PathType Leaf)) {
        throw ('Compilación incompleta: falta ' + $capcRelative)
    }
}
$capcCompiledAt = (Get-Item -LiteralPath (Join-Path $capcRelease 'data\app.so')).LastWriteTimeUtc
$capcSources = @(Get-ChildItem -LiteralPath (Join-Path $capcProject 'lib') -Recurse -File)
$capcSources += Get-Item -LiteralPath (Join-Path $capcProject 'pubspec.yaml')
if ($capcSources | Where-Object { $_.LastWriteTimeUtc -gt $capcCompiledAt }) {
    throw 'Hay código más reciente que la compilación. Ejecuta flutter build windows --release.'
}

# Each package is new. Never replace a running copy or the business database.
$capcName = 'CAPC-MULTISERVICIO-' + $Version + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$capcDestination = Join-Path $capcProject ('dist\' + $capcName)
New-Item -ItemType Directory -Path $capcDestination | Out-Null
Get-ChildItem -LiteralPath $capcRelease -Force | Copy-Item -Destination $capcDestination -Recurse
Copy-Item -LiteralPath (Join-Path $capcProject 'docs\ABRIR-Y-RESPALDAR.md') -Destination (Join-Path $capcDestination 'LEEME.md')
Copy-Item -LiteralPath (Join-Path $capcProject 'docs\GUIA-OPERACION.md') -Destination (Join-Path $capcDestination 'GUIA-OPERACION.md')
Copy-Item -LiteralPath (Join-Path $capcProject 'docs\RECUPERAR-ACCESO.md') -Destination (Join-Path $capcDestination 'RECUPERAR-ACCESO.md')
Copy-Item -LiteralPath (Join-Path $capcProject 'docs\EXCEL.md') -Destination (Join-Path $capcDestination 'EXCEL.md')

$capcFiles = Get-ChildItem -LiteralPath $capcDestination -Recurse -File
$capcManifest = foreach ($capcFile in $capcFiles) {
    $capcRelative = $capcFile.FullName.Substring($capcDestination.Length + 1)
    [PSCustomObject]@{
        Archivo = $capcRelative
        SHA256 = (Get-FileHash -LiteralPath $capcFile.FullName -Algorithm SHA256).Hash
        Bytes = $capcFile.Length
    }
}
$capcManifest | Export-Csv -LiteralPath (Join-Path $capcDestination 'SHA256.csv') -NoTypeInformation -Encoding UTF8

# Only point the launcher at the new release after the ZIP is complete.
$capcZip = $capcDestination + '.zip'
Compress-Archive -LiteralPath $capcDestination -DestinationPath $capcZip
$capcZipHash = (Get-FileHash -LiteralPath $capcZip -Algorithm SHA256).Hash
($capcZipHash + '  ' + (Split-Path -Leaf $capcZip)) | Set-Content -LiteralPath ($capcZip + '.sha256') -Encoding Ascii

$capcLauncher = @(
    '@echo off'
    'setlocal'
    ('cd /d "%~dp0dist\' + $capcName + '"')
    'if errorlevel 1 exit /b 1'
    'if not exist "capc_multi.exe" exit /b 1'
    'start "" "capc_multi.exe"'
)
$capcLauncher | Set-Content -LiteralPath (Join-Path $capcProject 'ABRIR_CAPC.cmd') -Encoding Ascii
[PSCustomObject]@{
    Version = $capcBuildVersion
    Creado = (Get-Date).ToUniversalTime().ToString('o')
    Carpeta = $capcDestination
    Ejecutable = Join-Path $capcDestination 'capc_multi.exe'
    Lanzador = Join-Path $capcProject 'ABRIR_CAPC.cmd'
    ZIP = $capcZip
    SHA256_ZIP = $capcZipHash
} | ConvertTo-Json | Tee-Object -FilePath (Join-Path $capcProject 'dist\ultima-version.json')
