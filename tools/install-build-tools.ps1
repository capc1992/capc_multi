param([switch]$Install)

$ErrorActionPreference = 'Stop'
$capcWorkspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$capcInstaller = Join-Path $capcWorkspace '.tools/installers/vs_BuildTools.exe'
$capcConfiguration = Join-Path $PSScriptRoot 'windows-build-tools.vsconfig'

if (-not $Install) {
    Write-Output 'Preparado: Microsoft Visual Studio 2022 Build Tools, compilador C++, CMake y Windows SDK 22621.'
    Write-Output 'La instalación necesita permisos de administrador y varios GB de descarga y disco.'
    Write-Output 'No reinicia Windows automáticamente. Ejecuta con -Install solo cuando vayas a instalar.'
    exit 0
}

if (-not (Test-Path -LiteralPath $capcInstaller)) {
    throw 'Falta el instalador oficial. Descárgalo de https://aka.ms/vs/17/release/vs_BuildTools.exe a .tools/installers/vs_BuildTools.exe.'
}
$capcSignature = Get-AuthenticodeSignature -FilePath $capcInstaller
if ($capcSignature.Status -ne 'Valid' -or $capcSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw 'No se pudo verificar la firma de Microsoft. La instalación se ha detenido.'
}
$capcIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$capcPrincipal = [Security.Principal.WindowsPrincipal]::new($capcIdentity)
if (-not $capcPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Abre PowerShell como administrador y vuelve a ejecutar este archivo con -Install.'
}
$capcArgs = @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--installPath', '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"',
    '--config', ('"' + $capcConfiguration + '"')
)
$capcProcess = Start-Process -FilePath $capcInstaller -ArgumentList $capcArgs -WindowStyle Hidden -Wait -PassThru
if ($capcProcess.ExitCode -eq 3010) {
    Write-Output 'Instalación terminada. Windows solicita un reinicio; guarda tu trabajo antes de reiniciar manualmente.'
} elseif ($capcProcess.ExitCode -ne 0) {
    throw ('El instalador terminó con código ' + $capcProcess.ExitCode + '. Revisa el registro de instalación de Microsoft.')
} else {
    Write-Output 'Herramientas de Windows instaladas. Ejecuta windows.ps1 -Action check para comprobarlas.'
}
