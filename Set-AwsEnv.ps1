<#

PURPOSE: Helps you log into AWS without saving secret keys to a file on disk. 

#>

function Set-AwsEnv {
    param (
        [string]$MfaSerial = "arn:aws:iam::278820798553:mfa/TOTP-1Password"
    )

    # 1. Clear any stale session token so STS uses base keys
    $env:AWS_SESSION_TOKEN = $null

    # 2. Prompt for single comma-delimited credential string
    Write-Host "Paste your comma-delimited AWS credential line below and press ENTER:" -ForegroundColor Cyan
    $inputString = Read-Host

    if (-not [string]::IsNullOrWhitespace($inputString)) {
        # Split by comma
        $entries = $inputString.Split(',')
        foreach ($entry in $entries) {
            # Split on the first '=' sign only
            $parts = $entry.Split('=', 2)
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim()
                Set-Item -Path "env:$key" -Value $val
                Write-Host "Set $key" -ForegroundColor Green
            }
        }
    }

    # 3. Prompt for MFA Code
    $mfaCode = Read-Host "`nEnter 6-digit MFA Code (or press ENTER to skip)"

    if (-not [string]::IsNullOrWhitespace($mfaCode)) {
        Write-Host "Requesting 12-hour MFA session token..." -ForegroundColor Yellow

        # Fetch STS session token and parse JSON into a PowerShell object
        $stsJson = aws sts get-session-token `
            --serial-number $MfaSerial `
            --token-code $mfaCode `
            --duration-seconds 43200 `
            --output json 2>$null | ConvertFrom-Json

        if ($LASTEXITCODE -eq 0 -and $stsJson.Credentials) {
            # Overwrite environment variables with temporary MFA session keys
            $env:AWS_ACCESS_KEY_ID     = $stsJson.Credentials.AccessKeyId
            $env:AWS_SECRET_ACCESS_KEY = $stsJson.Credentials.SecretAccessKey
            $env:AWS_SESSION_TOKEN     = $stsJson.Credentials.SessionToken
            Write-Host "MFA session token successfully applied!" -ForegroundColor Green
        } else {
            Write-Host "Failed to get MFA session token. Check your code or base keys." -ForegroundColor Red
            return
        }
    }

    # 4. Verify credentials immediately
    Write-Host "`nVerifying identity..." -ForegroundColor Cyan
    aws sts get-caller-identity
}

# Auto-execute when dot-sourced
Set-AwsEnv
# SIG # Begin signature block
# MIIFbQYJKoZIhvcNAQcCoIIFXjCCBVoCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUJbfeejWSxl7t0Gq2JzMQz80d
# hcKgggMIMIIDBDCCAeygAwIBAgIQKMluDSE+DYNJDjxooYUlHjANBgkqhkiG9w0B
# AQsFADAaMRgwFgYDVQQDDA9NeVNjcmlwdFNpZ25pbmcwHhcNMjYwODIxMTg0MTUz
# WhcNMjcwODIxMTkwMTUzWjAaMRgwFgYDVQQDDA9NeVNjcmlwdFNpZ25pbmcwggEi
# MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDdjksaORPLL4DTszsv4+cDB8qx
# nud1IM4kxWZOrn4zcBCzKwuSsKKLnEnz4dm0LHlt8wTPlpKnBgCM5B/vqPA0MeBy
# OJfBJOpFIeZ+JYwq/iPqRV+sRv4RvIU+qsbEpX58+kHyMXZMQrYqXnR1a1j4Fx6C
# lh87y4EL19h3WHCqYGV0S0gAjRRn1h71+ys4W4a8HxH3AwiroToxBTb2W5uuBhRg
# 05n1Qbv134ypCCS2VzHaaa9JtdpJeE6abwQgDLdedRfV8sZbcw0WAJyHfFqYUcr5
# 2Yu1GI8QOX4+4sN/Lhsc2lS+1s/fK8jtJ0tFLMNTYaDUzzf0+D6p4wJ2Y/qtAgMB
# AAGjRjBEMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzAdBgNV
# HQ4EFgQU6Qqp6MmCq1whh5Izp9A5lAH5YGMwDQYJKoZIhvcNAQELBQADggEBADxT
# wtDGLvHnTsyv8wYArD8ELf4+/uN3UaWgOWYwbkeh4fmuWZ5Jaw62d5+eQDC8k9yz
# D/9yYgx0rPIQe5r1eg8ne4Cf+OZJ6JPEDYu5fIBWRPBZaM9y8pYjKNA9vTBvufeE
# /jN0ZUxzsczk3TlWzL+6Vpfgx45T3eocd5zpBw2fZ7qNfXmqbRSpyj/bZWpxpzjK
# 2s2iFpXBZPO/V/9S7iurSqcHgV40d8f258Q0vFWMkor/llTJxN7HJERgiydU6Qi7
# kVNoncFg5s0GiWIvLsRzhPqQlyyQm/ThCF/ew70YaresZqgv7vCfGqoXjcyHu6hn
# 9ka+PSLsO8a231xmtJoxggHPMIIBywIBATAuMBoxGDAWBgNVBAMMD015U2NyaXB0
# U2lnbmluZwIQKMluDSE+DYNJDjxooYUlHjAJBgUrDgMCGgUAoHgwGAYKKwYBBAGC
# NwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQU7YjjlAJJ
# Fg+ziBd5ECUUFEddjkswDQYJKoZIhvcNAQEBBQAEggEAGQMAYDSSrP26fbB4k38U
# vJBbAqhxcSHSlyOe5q5QBu5iPxLPwTLwQk339xelmBoQUit4FY3EJZGjFU4ZHwKT
# jPBXHY80dQqmvpDwSvrWJq9G58bF8k5fiGtnaqHsXJ4q1X6cSpiBxfaAF2wWC4Ho
# YOzV0cMF+XVy46ETPPBQeHOnE4Ji9z5k+WJ5fZc8ffmOdYu4CcF20iPE8JTfLFJw
# rCZnDLt905YlayCD4ct/AMMdeVwzoJ+Sdv83YRtwHxPPLX1Fw4OoUA3zmMP++DPY
# 0UneExTbOm6XI6UHXd2QQBg9cD3yFx1sQllhX95TV1vFNvk1/n/tHpmsE+g8cnWv
# Uw==
# SIG # End signature block
