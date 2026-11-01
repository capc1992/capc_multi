param(
    [string]$SearchRoot = [Environment]::GetFolderPath('Desktop'),
    [switch]$NoLaunch,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Show-Result([string]$Message, [bool]$Success) {
    if ($Quiet) {
        if ($Success) {
            Write-Output $Message
            return
        }
        throw $Message
    }
    Add-Type -AssemblyName PresentationFramework
    $icon = if ($Success) { 'Information' } else { 'Error' }
    [System.Windows.MessageBox]::Show(
        $Message,
        'Actualizador CAPC piloto',
        'OK',
        $icon
    ) | Out-Null
}

try {
    $sourceRoot = $PSScriptRoot
    $sourceWindows = Join-Path $sourceRoot 'windows'
    $sourceExecutable = Join-Path $sourceWindows 'capc_multi.exe'
    $sourceSnapshot = Join-Path $sourceWindows 'data\app.so'
    if (-not (Test-Path -LiteralPath $sourceExecutable -PathType Leaf) -or
        -not (Test-Path -LiteralPath $sourceSnapshot -PathType Leaf)) {
        throw 'La carpeta del actualizador esta incompleta. Vuelve a copiarla desde el disco de desarrollo.'
    }

    $resolvedSearchRoot = (Resolve-Path -LiteralPath $SearchRoot).Path
    $launchers = @(Get-ChildItem -LiteralPath $resolvedSearchRoot `
        -Filter 'ABRIR-CAPC-PILOTO.cmd' -Recurse -File -ErrorAction Stop)
    $installations = @(
        foreach ($launcher in $launchers) {
            $root = $launcher.Directory.FullName
            if ((Test-Path -LiteralPath (Join-Path $root 'windows\capc_multi.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $root 'DATOS-PILOTO\CAPC\local\capc.sqlite3') -PathType Leaf)) {
                [PSCustomObject]@{ Root = $root; Launcher = $launcher.FullName }
            }
        }
    )
    if ($installations.Count -eq 0) {
        throw 'No se encontro una instalacion piloto con DATOS-PILOTO en el Escritorio.'
    }
    if ($installations.Count -ne 1) {
        $paths = ($installations.Root | Sort-Object) -join "`n"
        throw "Se encontraron varias instalaciones piloto. Conserva solo una instalacion activa en el Escritorio y vuelve a intentarlo:`n$paths"
    }

    $targetRoot = $installations[0].Root
    $targetWindows = Join-Path $targetRoot 'windows'
    $targetData = Join-Path $targetRoot 'DATOS-PILOTO'
    $resolvedTargetWindows = (Resolve-Path -LiteralPath $targetWindows).Path
    $runningTarget = @(
        foreach ($process in Get-Process -Name 'capc_multi' -ErrorAction SilentlyContinue) {
            try {
                if ($process.Path -and $process.Path.StartsWith(
                    $resolvedTargetWindows,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) { $process }
            } catch {
                $process
            }
        }
    )
    if ($runningTarget.Count -gt 0) {
        throw 'CAPC esta abierto. Cierralo completamente y vuelve a dar doble clic al actualizador.'
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupParent = Join-Path $targetRoot 'RESPALDOS-ACTUALIZACION'
    $backup = Join-Path $backupParent ('DATOS-PILOTO-' + $stamp)
    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
    Copy-Item -LiteralPath $targetData -Destination $backup -Recurse

    Get-ChildItem -LiteralPath $sourceWindows -Force |
        Copy-Item -Destination $targetWindows -Recurse -Force

    $differences = @(
        foreach ($sourceFile in Get-ChildItem -LiteralPath $sourceWindows -Recurse -File) {
            $relative = $sourceFile.FullName.Substring($sourceWindows.Length + 1)
            $targetFile = Join-Path $targetWindows $relative
            if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
                $relative
                continue
            }
            $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
            $targetHash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
            if ($sourceHash -ne $targetHash) { $relative }
        }
    )
    if ($differences.Count -gt 0) {
        throw ('La copia no se pudo verificar. Archivos pendientes: ' + ($differences -join ', '))
    }
    if (-not (Test-Path -LiteralPath (Join-Path $targetData 'CAPC\local\capc.sqlite3') -PathType Leaf)) {
        throw 'La base piloto no esta disponible despues de la actualizacion.'
    }

    $log = Join-Path $targetRoot ('ACTUALIZACION-CONSECUTIVO-' + $stamp + '.txt')
    @(
        'Actualizacion CAPC piloto completada.'
        ('Fecha: ' + (Get-Date).ToString('o'))
        ('Instalacion: ' + $targetRoot)
        ('Respaldo: ' + $backup)
        ('Ejecutable SHA-256: ' + (Get-FileHash -LiteralPath (Join-Path $targetWindows 'capc_multi.exe') -Algorithm SHA256).Hash)
    ) | Set-Content -LiteralPath $log -Encoding UTF8

    Show-Result "Actualizacion completada y verificada.`n`nRespaldo:`n$backup`n`nCAPC conservara sus datos y se abrira ahora." $true
    if (-not $NoLaunch) {
        Start-Process -FilePath $installations[0].Launcher -WindowStyle Hidden
    }
} catch {
    Show-Result $_.Exception.Message $false
    exit 1
}
