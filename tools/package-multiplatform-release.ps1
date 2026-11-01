param(
    [Parameter(Mandatory = $true)]
    [string]$AndroidApk,
    [Parameter(Mandatory = $true)]
    [string]$WindowsInstaller,
    [Parameter(Mandatory = $true)]
    [string]$IosIpa,
    [string]$Version = '0.4.2-9'
)

$ErrorActionPreference = 'Stop'
$capcProject = Split-Path -Parent $PSScriptRoot
$capcInputs = @($AndroidApk, $WindowsInstaller, $IosIpa)
foreach ($capcInput in $capcInputs) {
    if (-not (Test-Path -LiteralPath $capcInput -PathType Leaf)) {
        throw ('No existe el artefacto requerido: ' + $capcInput)
    }
}

$capcDestination = Join-Path $capcProject ('dist\CAPC-MULTIPLATAFORMA-' + $Version)
if (Test-Path -LiteralPath $capcDestination) {
    throw ('La carpeta de entrega ya existe: ' + $capcDestination)
}
$capcAndroid = Join-Path $capcDestination 'Android'
$capcWindows = Join-Path $capcDestination 'Windows'
$capcIos = Join-Path $capcDestination 'iOS'
New-Item -ItemType Directory -Path $capcAndroid | Out-Null
New-Item -ItemType Directory -Path $capcWindows | Out-Null
New-Item -ItemType Directory -Path $capcIos | Out-Null

$capcApkTarget = Join-Path $capcAndroid ('CAPC-MULTISERVICIO-' + $Version + '-release.apk')
$capcExeTarget = Join-Path $capcWindows ('CAPC-MULTISERVICIO-Setup-' + $Version.Split('-')[0] + '.exe')
$capcIpaTarget = Join-Path $capcIos ('CAPC-MULTISERVICIO-' + $Version + '-sideloadly.ipa')
Copy-Item -LiteralPath $AndroidApk -Destination $capcApkTarget
Copy-Item -LiteralPath $WindowsInstaller -Destination $capcExeTarget
Copy-Item -LiteralPath $IosIpa -Destination $capcIpaTarget

$capcArtifacts = @($capcApkTarget, $capcExeTarget, $capcIpaTarget)
$capcManifest = foreach ($capcArtifact in $capcArtifacts) {
    $capcHash = (Get-FileHash -LiteralPath $capcArtifact -Algorithm SHA256).Hash
    ($capcHash + '  ' + (Split-Path -Leaf $capcArtifact)) |
        Set-Content -LiteralPath ($capcArtifact + '.sha256') -Encoding Ascii
    [PSCustomObject]@{
        Archivo = $capcArtifact.Substring($capcDestination.Length + 1)
        Bytes = (Get-Item -LiteralPath $capcArtifact).Length
        SHA256 = $capcHash
    }
}
$capcManifest | ConvertTo-Json | Set-Content -LiteralPath (
    Join-Path $capcDestination 'MANIFIESTO.json'
) -Encoding UTF8

@'
CAPC MULTISERVICIO 0.4.2+9

Android:
- Instala el APK release. Autoriza la instalación desde la aplicación usada para abrirlo.
- Conserva siempre la misma firma para poder actualizar sin perder la instalación.

Windows:
- Ejecuta el instalador EXE. Esta entrega no tiene firma comercial y Windows puede mostrar SmartScreen.
- Verifica primero el archivo SHA-256 incluido.

iPhone/iPad:
- Descarga Sideloadly únicamente desde https://sideloadly.io/
- Arrastra la IPA a Sideloadly, conecta el dispositivo y firma con tu Apple ID.
- Usa el mismo Apple ID en futuras actualizaciones para conservar la instalación.

Los tres clientes se conectan a https://api.capcmultiservicios.site.
'@ | Set-Content -LiteralPath (Join-Path $capcDestination 'LEEME-INSTALACION.txt') -Encoding UTF8

[PSCustomObject]@{
    Version = '0.4.2+9'
    Carpeta = $capcDestination
    Android = $capcApkTarget
    Windows = $capcExeTarget
    iOS = $capcIpaTarget
} | ConvertTo-Json
