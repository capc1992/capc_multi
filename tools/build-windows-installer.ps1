param(
    [string]$CompilerPath,
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$capcProject = Split-Path -Parent $PSScriptRoot
$capcRelease = Join-Path $capcProject 'build\windows\x64\runner\Release'
$capcExecutable = Join-Path $capcRelease 'capc_multi.exe'
$capcScript = Join-Path $capcProject 'installer\capc_multiservicio.iss'

$capcPubspec = Get-Content -LiteralPath (Join-Path $capcProject 'pubspec.yaml') -Raw
$capcVersionMatch = [regex]::Match($capcPubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $capcVersionMatch.Success) { throw 'No se pudo leer la versión en pubspec.yaml.' }
$capcSourceVersion = $capcVersionMatch.Groups[1].Value
$capcBuildNumber = $capcVersionMatch.Groups[2].Value
$capcBuildVersion = $capcSourceVersion + '.' + $capcBuildNumber
if (-not $Version) { $Version = $capcSourceVersion }
if ($Version -ne $capcSourceVersion) { throw 'La versión del instalador debe coincidir con pubspec.yaml.' }

if (-not (Test-Path -LiteralPath $capcExecutable -PathType Leaf)) {
    throw 'Primero ejecuta flutter build windows --release --no-pub.'
}
if ((Get-Item -LiteralPath $capcExecutable).VersionInfo.ProductVersion -ne ($capcSourceVersion + '+' + $capcBuildNumber)) {
    throw 'El ejecutable pertenece a otra versión. Recompila Windows release.'
}
$capcRequired = @(
    'flutter_windows.dll', 'sqlite3.dll', 'pdfium.dll',
    'printing_plugin.dll', 'file_selector_windows_plugin.dll',
    'flutter_secure_storage_windows_plugin.dll',
    'data\app.so', 'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin'
)
foreach ($capcRelative in $capcRequired) {
    if (-not (Test-Path -LiteralPath (Join-Path $capcRelease $capcRelative) -PathType Leaf)) {
        throw ('Compilación incompleta: falta ' + $capcRelative)
    }
}

if (-not $CompilerPath) {
    $capcCandidates = @(
        (Join-Path $capcProject 'tmp\inno\ISCC.exe'),
        'C:\Program Files\Inno Setup 7\ISCC.exe',
        'C:\Program Files (x86)\Inno Setup 7\ISCC.exe',
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    )
    $CompilerPath = $capcCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $CompilerPath) {
    $capcCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($capcCommand) { $CompilerPath = $capcCommand.Source }
}
if (-not $CompilerPath -or -not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
    throw 'No se encontró ISCC.exe. Instala Inno Setup 7 o pasa -CompilerPath.'
}

$capcCompiledAt = (Get-Item -LiteralPath (Join-Path $capcRelease 'data\app.so')).LastWriteTimeUtc
$capcSources = @(Get-ChildItem -LiteralPath (Join-Path $capcProject 'lib') -Recurse -File)
$capcSources += Get-Item -LiteralPath (Join-Path $capcProject 'pubspec.yaml')
if ($capcSources | Where-Object { $_.LastWriteTimeUtc -gt $capcCompiledAt }) {
    throw 'Hay código más reciente que la compilación. Recompila Windows release.'
}

$capcDist = Join-Path $capcProject 'dist'
New-Item -ItemType Directory -Path $capcDist -Force | Out-Null
& $CompilerPath /Qp `
    ('/DMyAppVersion=' + $Version) `
    ('/DMyAppBuildVersion=' + $capcBuildVersion) `
    ('/DReleaseDir=' + $capcRelease) `
    ('/DProjectDir=' + $capcProject) `
    $capcScript
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup no pudo compilar el instalador.' }

$capcInstaller = Join-Path $capcDist ('CAPC-MULTISERVICIO-Setup-' + $Version + '.exe')
if (-not (Test-Path -LiteralPath $capcInstaller -PathType Leaf)) {
    throw 'El compilador no generó el instalador esperado.'
}
$capcHash = (Get-FileHash -LiteralPath $capcInstaller -Algorithm SHA256).Hash
($capcHash + '  ' + (Split-Path -Leaf $capcInstaller)) |
    Set-Content -LiteralPath ($capcInstaller + '.sha256') -Encoding Ascii
$capcSignature = Get-AuthenticodeSignature -LiteralPath $capcInstaller
[PSCustomObject]@{
    Version = $capcSourceVersion + '+' + $capcBuildNumber
    Instalador = $capcInstaller
    Bytes = (Get-Item -LiteralPath $capcInstaller).Length
    SHA256 = $capcHash
    Firma = $capcSignature.Status.ToString()
    NotaFirma = if ($capcSignature.Status -eq 'Valid') { 'Firmado digitalmente.' } else { 'Sin firma comercial; Windows puede mostrar una advertencia.' }
} | ConvertTo-Json
