param(
    [ValidateSet('check', 'test', 'run', 'build')]
    [string]$Action = 'check'
)

$ErrorActionPreference = 'Stop'
$capcProject = Split-Path -Parent $PSScriptRoot
$capcBundledFlutter = Join-Path $capcProject '.tools/flutter/bin/flutter.bat'
$capcInstalledFlutter = Get-Command flutter -ErrorAction SilentlyContinue

if ($capcInstalledFlutter) {
    $capcFlutter = $capcInstalledFlutter.Source
} elseif (Test-Path -LiteralPath $capcBundledFlutter) {
    $capcFlutter = $capcBundledFlutter
    $env:PUB_CACHE = Join-Path $capcProject '.tools/pub-cache'
} else {
    throw 'Flutter no está disponible. Consulta README.md para preparar el equipo.'
}

Push-Location $capcProject
try {
    if ($Action -eq 'check') {
        & $capcFlutter doctor -v
    } else {
        & $capcFlutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'No se pudieron resolver las dependencias.' }
        switch ($Action) {
            'test' {
                & $capcFlutter analyze
                if ($LASTEXITCODE -ne 0) { throw 'La revisión de código encontró problemas.' }
                & $capcFlutter test
            }
            'run' { & $capcFlutter run -d windows }
            'build' { & $capcFlutter build windows --release }
        }
    }
    if ($LASTEXITCODE -ne 0) { throw 'La operación no terminó correctamente. Revisa los mensajes anteriores.' }
} finally {
    Pop-Location
}
