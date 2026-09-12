param([Parameter(Mandatory=$true)][string]$RequestPath, [Parameter(Mandatory=$true)][string]$ResultPath)
$ErrorActionPreference = 'Stop'
try {
    $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -ne $request.user_sid) { throw 'Approve using the same Windows account as Dyno Worker.' }
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator approval is required.' }
    $program = (Resolve-Path -LiteralPath $request.program).Path
    if ([IO.Path]::GetExtension($program) -ne '.exe') { throw 'Expected the Dyno executable path.' }
    if (-not @(Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Private').Count) {
        throw 'Choose your trusted LAN as Private in Windows Settings before enabling discovery.'
    }
    foreach ($entry in @(@{name='Dyno-Worker-Discovery'; protocol='UDP'; port=5353},
                          @{name='Dyno-Worker-Pairing'; protocol='TCP'; port=50053})) {
        Get-NetFirewallRule -Name $entry.name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -Name $entry.name -DisplayName $entry.name -Direction Inbound -Action Allow `
            -Protocol $entry.protocol -LocalPort $entry.port -Profile Private -RemoteAddress LocalSubnet `
            -Program $program | Out-Null
    }
    'Discovery enabled for this app on Private local networks. GPU RPC remains loopback-only.' |
        Set-Content -LiteralPath $ResultPath -Encoding utf8
    exit 0
} catch {
    ('Discovery setup failed: ' + $_.Exception.Message) | Set-Content -LiteralPath $ResultPath -Encoding utf8
    exit 1
}
