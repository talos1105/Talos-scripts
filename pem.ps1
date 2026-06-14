# Generate ECDSA P-256 Key Pair
# Compatible with Windows 10/11 PowerShell 5.1+

Add-Type -AssemblyName System.Security

# Create ECDSA key using CngKey (more compatible)
$cngParams = [System.Security.Cryptography.CngKeyCreationParameters]::new()
$cngParams.ExportPolicy = [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
$cngKey    = [System.Security.Cryptography.CngKey]::Create(
    [System.Security.Cryptography.CngAlgorithm]::ECDsaP256,
    $null,
    $cngParams
)
$ecdsa = [System.Security.Cryptography.ECDsaCng]::new($cngKey)

# Export private key (PKCS8)
$privateBytes = $ecdsa.Key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
$privateB64   = [Convert]::ToBase64String($privateBytes, [Base64FormattingOptions]::InsertLineBreaks)
$privatePem   = "-----BEGIN EC PRIVATE KEY-----`r`n$privateB64`r`n-----END EC PRIVATE KEY-----"

# Export public key (SPKI)
$publicBytes  = $ecdsa.Key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
$publicB64    = [Convert]::ToBase64String($publicBytes, [Base64FormattingOptions]::InsertLineBreaks)
$publicPem    = "-----BEGIN PUBLIC KEY-----`r`n$publicB64`r`n-----END PUBLIC KEY-----"

# Save to files
$privatePem | Out-File -FilePath "private.pem" -Encoding ASCII
$publicPem  | Out-File -FilePath "public.pem"  -Encoding ASCII

# Display result
Write-Host ""
Write-Host "=== PRIVATE KEY (paste into ESP32 firmware) ===" -ForegroundColor Yellow
Write-Host $privatePem
Write-Host ""
Write-Host "=== PUBLIC KEY (paste into Cloudflare KV) ===" -ForegroundColor Cyan
Write-Host $publicPem
Write-Host ""
Write-Host "Files saved: private.pem, public.pem" -ForegroundColor Green
