param(
    [string]$ExpectedSyncUrl = 'https://api-test.capcmultiservicios.site',
    [string]$ExpectedCredentialNamespace = 'pilot-2026-10'
)

$ErrorActionPreference = 'Stop'
$capcProject = Split-Path -Parent $PSScriptRoot
$capcWindowsRelease = Join-Path $capcProject 'build\windows\x64\runner\Release'
$capcExecutable = Join-Path $capcWindowsRelease 'capc_multi.exe'
$capcAppSnapshot = Join-Path $capcWindowsRelease 'data\app.so'
$capcApk = Join-Path $capcProject 'build\app\outputs\flutter-apk\app-debug.apk'

foreach ($capcRequiredFile in @($capcExecutable, $capcAppSnapshot, $capcApk)) {
    if (-not (Test-Path -LiteralPath $capcRequiredFile -PathType Leaf)) {
        throw ('Falta el artefacto compilado: ' + $capcRequiredFile)
    }
}

$capcPubspec = Get-Content -LiteralPath (Join-Path $capcProject 'pubspec.yaml') -Raw
$capcVersionMatch = [regex]::Match(
    $capcPubspec,
    '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$'
)
if (-not $capcVersionMatch.Success) {
    throw 'No se pudo leer la version en pubspec.yaml.'
}
$capcBuildVersion = $capcVersionMatch.Groups[1].Value + '+' +
    $capcVersionMatch.Groups[2].Value
if ((Get-Item -LiteralPath $capcExecutable).VersionInfo.ProductVersion -ne $capcBuildVersion) {
    throw 'El ejecutable de Windows pertenece a otra version.'
}

$capcSnapshotBytes = [System.IO.File]::ReadAllBytes($capcAppSnapshot)
$capcSnapshotText = [System.Text.Encoding]::UTF8.GetString($capcSnapshotBytes)
if (-not $capcSnapshotText.Contains($ExpectedSyncUrl)) {
    throw 'El cliente Windows no contiene la URL esperada del piloto.'
}
if (-not $capcSnapshotText.Contains($ExpectedCredentialNamespace)) {
    throw 'El cliente Windows no contiene el espacio de credenciales del piloto.'
}

$capcCompiledAt = (Get-Item -LiteralPath $capcAppSnapshot).LastWriteTimeUtc
$capcSources = @(Get-ChildItem -LiteralPath (Join-Path $capcProject 'lib') -Recurse -File)
$capcSources += Get-Item -LiteralPath (Join-Path $capcProject 'pubspec.yaml')
if ($capcSources | Where-Object { $_.LastWriteTimeUtc -gt $capcCompiledAt }) {
    throw 'Hay codigo mas reciente que la compilacion de Windows.'
}

$capcName = 'CAPC-PILOTO-AISLADO-' + $capcBuildVersion.Replace('+', '-') + '-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$capcDestination = Join-Path $capcProject ('dist\' + $capcName)
$capcWindowsDestination = Join-Path $capcDestination 'windows'
$capcAndroidDestination = Join-Path $capcDestination 'android'
New-Item -ItemType Directory -Path $capcWindowsDestination | Out-Null
New-Item -ItemType Directory -Path $capcAndroidDestination | Out-Null

Get-ChildItem -LiteralPath $capcWindowsRelease -Force |
    Copy-Item -Destination $capcWindowsDestination -Recurse
Copy-Item -LiteralPath $capcApk -Destination (
    Join-Path $capcAndroidDestination 'CAPC-MULTISERVICIO-PILOTO-debug.apk'
)
Copy-Item -LiteralPath (Join-Path $capcProject 'docs\PILOTO-CLIENTES.md') `
    -Destination (Join-Path $capcDestination 'LEEME-PILOTO.md')
Copy-Item -LiteralPath (Join-Path $capcProject 'docs\VALIDACION-OFFLINE-FIRST.md') `
    -Destination (Join-Path $capcDestination 'VALIDACION-OFFLINE-FIRST.md')

$capcLauncher = @(
    '@echo off'
    'setlocal'
    'cd /d "%~dp0"'
    'if errorlevel 1 exit /b 1'
    'if not exist "windows\capc_multi.exe" exit /b 1'
    'if not exist "DATOS-PILOTO" mkdir "DATOS-PILOTO"'
    'set "CAPC_DATA_DIR=%~dp0DATOS-PILOTO"'
    'start "CAPC PILOTO" "windows\capc_multi.exe"'
)
$capcLauncher | Set-Content -LiteralPath (
    Join-Path $capcDestination 'ABRIR-CAPC-PILOTO.cmd'
) -Encoding Ascii

$capcMetadata = [PSCustomObject]@{
    Nombre = $capcName
    Version = $capcBuildVersion
    Tipo = 'piloto'
    SyncUrl = $ExpectedSyncUrl
    CredentialNamespace = $ExpectedCredentialNamespace
    Creado = (Get-Date).ToUniversalTime().ToString('o')
    DatosWindows = 'DATOS-PILOTO'
    Android = 'debug-no-publicable'
}
$capcMetadata | ConvertTo-Json | Set-Content -LiteralPath (
    Join-Path $capcDestination 'PILOTO.json'
) -Encoding UTF8

$capcFiles = Get-ChildItem -LiteralPath $capcDestination -Recurse -File
$capcManifest = foreach ($capcFile in $capcFiles) {
    [PSCustomObject]@{
        Archivo = $capcFile.FullName.Substring($capcDestination.Length + 1)
        SHA256 = (Get-FileHash -LiteralPath $capcFile.FullName -Algorithm SHA256).Hash
        Bytes = $capcFile.Length
    }
}
$capcManifest | Export-Csv -LiteralPath (
    Join-Path $capcDestination 'SHA256.csv'
) -NoTypeInformation -Encoding UTF8

$capcForbiddenData = Get-ChildItem -LiteralPath $capcDestination -Recurse -File |
    Where-Object { $_.Extension -in @('.db', '.sqlite', '.sqlite3') }
if ($capcForbiddenData) {
    throw 'El paquete contiene una base de datos y no es seguro distribuirlo.'
}

$capcZip = $capcDestination + '.zip'
Compress-Archive -LiteralPath $capcDestination -DestinationPath $capcZip
$capcZipHash = (Get-FileHash -LiteralPath $capcZip -Algorithm SHA256).Hash
($capcZipHash + '  ' + (Split-Path -Leaf $capcZip)) | Set-Content `
    -LiteralPath ($capcZip + '.sha256') -Encoding Ascii

[PSCustomObject]@{
    Version = $capcBuildVersion
    Carpeta = $capcDestination
    ZIP = $capcZip
    SHA256_ZIP = $capcZipHash
    Archivos = (Get-ChildItem -LiteralPath $capcDestination -Recurse -File).Count
} | ConvertTo-Json
