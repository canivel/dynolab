param([Parameter(Mandatory=$true)][string]$RequestPath, [Parameter(Mandatory=$true)][string]$ResultPath, [string]$StatusPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Report-Stage([string]$Message) {
    if ($StatusPath) { $Message | Set-Content -LiteralPath $StatusPath -Encoding utf8 }
}
function Protect-AuthorizedKeys([string]$Path) {
    # Replacing only these two grants with icacls leaves unrelated explicit ACEs.
    # OpenSSH requires the entire DACL to contain only SYSTEM and Administrators.
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
try {
    Report-Stage 'Checking Windows account and local network…'
    $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -ne $request.user_sid) { throw 'Approve setup using the same Windows account that opened Dyno Worker.' }
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Windows administrator approval is required.' }
    $ip = [Net.IPAddress]::Parse($request.mac_address)
    $octets = $ip.GetAddressBytes()
    if ($octets.Length -ne 4 -or -not ($octets[0] -eq 10 -or ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or ($octets[0] -eq 192 -and $octets[1] -eq 168))) { throw 'Use the Mac private LAN IPv4 address.' }
    $key = [string]$request.public_key
    if ($key -notmatch '^ssh-ed25519 [A-Za-z0-9+/]{68}$') { throw 'Invalid Ed25519 public key.' }
    $decoded = [Convert]::FromBase64String($key.Split(' ')[1])
    if ($decoded.Length -ne 51) { throw 'Invalid Ed25519 key length.' }
    $matching = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $entry = $_
        $profile = Get-NetConnectionProfile -InterfaceIndex $entry.InterfaceIndex -ErrorAction SilentlyContinue
        if ($profile.NetworkCategory -ne 'Private' -or $entry.IPAddress -eq $ip.ToString()) { return $false }
        $localBytes = ([Net.IPAddress]::Parse($entry.IPAddress)).GetAddressBytes()
        $same = $true
        for ($bit = 0; $bit -lt $entry.PrefixLength; $bit++) {
            $idx = [int][Math]::Floor($bit / 8)
            $mask = 1 -shl (7 - ($bit % 8))
            if (($localBytes[$idx] -band $mask) -ne ($octets[$idx] -band $mask)) { $same = $false }
        }
        return $same
    })
    if ($matching.Count -eq 0) { throw 'No Private network shares the Mac subnet. Set your trusted LAN to Private in Windows Settings and check the address.' }
    Report-Stage 'Checking the Windows OpenSSH component…'
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    $newInstall = $capability.State -ne 'Installed'
    if ($newInstall) {
        Report-Stage 'Installing OpenSSH through Windows Update. The first setup can take several minutes. Keep Dyno open; download progress is managed by Windows.'
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }
    # Only suppress the broad default rule when this setup just installed OpenSSH.
    # Existing SSH configuration and firewall rules belong to the user.
    if ($newInstall) { Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule }
    Report-Stage 'Starting the secure connection service…'
    Start-Service sshd
    $config = Get-Content "$env:ProgramData\ssh\sshd_config" -Raw
    if ($config -match '(?m)^\s*Port\s+(?!(?:22|50054)\s*(?:#.*)?$)\d+' -or $config -match '(?im)^\s*AllowTcpForwarding\s+no') { throw 'Existing SSH configuration is customized. Configure compatible SSH ports and local forwarding before pairing.' }
    if ($config -notmatch '(?im)^\s*AuthorizedKeysFile\s+__PROGRAMDATA__/ssh/administrators_authorized_keys') { throw 'Custom administrator key configuration detected. Pair manually; no key file was changed.' }
    $sshPort = if ($request.automatic -eq $true) { 50054 } else { 22 }
    $sshDir = Join-Path $env:WINDIR 'System32\OpenSSH'
    $service = Get-CimInstance Win32_Service -Filter "Name='sshd'"
    if ($sshPort -eq 50054) {
        Report-Stage 'Preparing a dedicated SSH endpoint for Dyno, separate from other SSH services…'
        $listeners = @(Get-NetTCPConnection -LocalPort $sshPort -State Listen -ErrorAction SilentlyContinue)
        if (@($listeners | Where-Object OwningProcess -ne $service.ProcessId).Count) { throw 'Dyno SSH port 50054 is occupied by another service. Existing service was preserved.' }
        if ($config -notmatch '(?m)^\s*Port\s+50054\s*(?:#.*)?$') {
            if ($config -match '(?im)^\s*(Include|ListenAddress)\s+') { throw 'Custom SSH listener configuration detected; automatic endpoint setup cannot safely edit it.' }
            $prefix = "# Dyno dedicated SSH endpoint`r`nPort 50054`r`n"
            if ($config -notmatch '(?im)^\s*Port\s+') { $prefix += "Port 22`r`n" }
            $candidate = $prefix + $config
            $candidatePath = Join-Path (Split-Path -Parent $RequestPath) 'sshd_config.check'
            $candidate | Set-Content -LiteralPath $candidatePath -Encoding ascii
            & "$sshDir\sshd.exe" -t -f $candidatePath
            if ($LASTEXITCODE -ne 0) { throw 'Dedicated SSH configuration failed validation. Existing configuration was preserved.' }
            $configPath = "$env:ProgramData\ssh\sshd_config"
            Copy-Item -LiteralPath $configPath -Destination ($configPath + '.dyno-backup-' + [Guid]::NewGuid().ToString('N'))
            try {
                $candidate | Set-Content -LiteralPath $configPath -Encoding ascii
                Restart-Service sshd
            } catch {
                $config | Set-Content -LiteralPath $configPath -Encoding ascii
                Restart-Service sshd
                throw 'Could not activate the Dyno SSH endpoint; restored previous configuration.'
            }
        }
    }
    Report-Stage 'Verifying the SSH endpoint identity before authorizing the coordinator…'
    $service = Get-CimInstance Win32_Service -Filter "Name='sshd'"
    $listeners = @(Get-NetTCPConnection -LocalPort $sshPort -State Listen -ErrorAction SilentlyContinue)
    if (-not @($listeners | Where-Object { $_.OwningProcess -eq $service.ProcessId -and $_.LocalAddress -in @('0.0.0.0') + @($matching.IPAddress) }).Count) { throw 'The native Windows SSH service is not listening on the selected IPv4 endpoint.' }
    if (@($listeners | Where-Object { $_.OwningProcess -ne $service.ProcessId -and $_.LocalAddress -in @('0.0.0.0') + @($matching.IPAddress) }).Count) { throw 'Another service is answering on the SSH endpoint. Use automatic pairing for a dedicated Dyno endpoint.' }
    $hostKey = (Get-Content -LiteralPath "$env:ProgramData\ssh\ssh_host_ed25519_key.pub" -Raw).Trim()
    $expectedKey = ($hostKey -split '\s+')[0..1] -join ' '
    $scanError = Join-Path (Split-Path -Parent $RequestPath) 'keyscan.stderr'
    foreach ($entry in $matching) {
        # Windows PowerShell treats the normal SSH banner on stderr as an error
        # under Stop, even when ssh-keyscan succeeds. Check exit status and key.
        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $scanned = @(& "$sshDir\ssh-keyscan.exe" -T 5 -p $sshPort -t ed25519 $entry.IPAddress 2> $scanError)
            $scanExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorAction }
        $keys = @($scanned | Where-Object { $_ -match '^\S+\s+ssh-ed25519\s+' } | ForEach-Object { ($_ -split '\s+')[1..2] -join ' ' })
        if ($scanExit -ne 0 -or $expectedKey -notin $keys -or @($keys | Where-Object { $_ -ne $expectedKey }).Count) { throw 'SSH endpoint identity verification failed. No new coordinator key was installed; trust was not changed.' }
    }
    Report-Stage 'Authorizing this coordinator and applying restricted SSH access…'
    $keysPath = "$env:ProgramData\ssh\administrators_authorized_keys"
    $marker = 'dyno-worker-' + $request.user_sid + '-' + $ip.ToString()
    $existing = if (Test-Path $keysPath) { @(Get-Content -LiteralPath $keysPath) } else { @() }
    $retained = @($existing | Where-Object { -not $_.EndsWith(' ' + $marker) })
    $line = 'from="' + $ip.ToString() + '",restrict,port-forwarding,permitopen="127.0.0.1:50052",command="echo Dyno forwarding only" ' + $key + ' ' + $marker
    # Protect a new file before adding the key, and preserve other authorized keys.
    if (-not (Test-Path $keysPath)) { New-Item -ItemType File -Path $keysPath | Out-Null }
    Protect-AuthorizedKeys $keysPath
    ($retained + $line) | Set-Content -LiteralPath $keysPath -Encoding ascii
    $ruleName = 'Dyno-Worker-SSH-' + $ip.ToString()
    Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $ruleName -DisplayName 'Dyno Worker - paired coordinator SSH' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $sshPort -Profile Private -RemoteAddress $ip.ToString() -LocalAddress @($matching.IPAddress) -Program "$sshDir\sshd.exe" | Out-Null
    Set-Service sshd -StartupType Automatic
    $fingerprint = & "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" -lf "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the SSH host fingerprint.' }
    Report-Stage 'Connection setup complete. Returning the verified host key to your coordinator…'
    $username = $identity.Name.Split('\')[-1]
    if ($request.automatic -eq $true) {
        @{user=$username; host_key=$hostKey; ssh_port=$sshPort; revision='5bda51bfbc62e64193221e639f6ad4e08767d760'} |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -Encoding utf8
        exit 0
    }
    @"
LAN setup complete.
Windows address: $($matching.IPAddress -join ', ')
Windows username: $username
SSH port: $sshPort; GPU port: 50052 (loopback only)
Verify this host fingerprint on your Mac before connecting:
$fingerprint
Existing SSH/firewall settings were preserved. Their access rules may be broader than Dyno's rule.
"@ | Set-Content -LiteralPath $ResultPath -Encoding utf8
    exit 0
} catch {
    Report-Stage ('Setup needs attention: ' + $_.Exception.Message)
    ("Setup failed: " + $_.Exception.Message + "`nAny completed Windows setup steps remain in place; retry after correcting the problem.") | Set-Content -LiteralPath $ResultPath -Encoding utf8
    exit 1
}
