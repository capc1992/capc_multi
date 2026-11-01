param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [Parameter(Mandatory = $true)][string]$ExpectedPublisher
)

$ErrorActionPreference = 'Stop'
if (-not $env:CAPC_WINDOWS_CERT_PASSWORD) {
    throw 'Falta CAPC_WINDOWS_CERT_PASSWORD para firmar Windows.'
}
$capcSignTool = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source
if (-not $capcSignTool) {
    $capcSignTool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $capcSignTool) { throw 'No se encontró signtool.exe.' }

& $capcSignTool sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com /f $CertificatePath /p $env:CAPC_WINDOWS_CERT_PASSWORD $FilePath
if ($LASTEXITCODE -ne 0) { throw 'Falló la firma Authenticode.' }
& $capcSignTool verify /pa /all $FilePath
if ($LASTEXITCODE -ne 0) { throw 'La firma Authenticode no pasó la verificación.' }
$capcSignature = Get-AuthenticodeSignature -LiteralPath $FilePath
if ($capcSignature.Status -ne 'Valid') { throw ('Firma inválida: ' + $capcSignature.Status) }
$capcPublisher = $capcSignature.SignerCertificate.GetNameInfo(
    [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
    $false
)
if (-not $capcPublisher.Equals($ExpectedPublisher.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'El editor del certificado no coincide con WINDOWS_EXPECTED_PUBLISHER.'
}
Write-Output ('Firma válida para ' + (Split-Path -Leaf $FilePath))
