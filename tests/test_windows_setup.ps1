# Native Windows test: no OpenSSH, firewall, service or real key-file changes.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\worker\windows\setup-lan.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors }
$fn = $ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Protect-AuthorizedKeys'
}, $true)
. ([scriptblock]::Create($fn.Extent.Text))
$testFile = Join-Path $env:TEMP ('dyno-acl-test-' + [guid]::NewGuid().ToString() + '.txt')
try {
    Set-Content -LiteralPath $testFile -Value 'preserved existing public key entry'
    & icacls.exe $testFile /grant '*S-1-1-0:R' | Out-Null
    if ($LASTEXITCODE) { throw 'Could not prepare ACL fixture' }
    Protect-AuthorizedKeys $testFile
    $acl = Get-Acl -LiteralPath $testFile
    $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
    if ($sids.Count -ne 2 -or 'S-1-5-32-544' -notin $sids -or 'S-1-5-18' -notin $sids -or -not $acl.AreAccessRulesProtected) {
        throw 'Expected only SYSTEM and Administrators, with inheritance disabled'
    }
    # Restore the test owner's access so a non-elevated test can verify content.
    & icacls.exe $testFile /grant ('*' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + ':F') | Out-Null
    if ($LASTEXITCODE) { throw 'Could not restore test-owner access' }
    if ((Get-Content -LiteralPath $testFile) -ne 'preserved existing public key entry') { throw 'File contents changed' }
    Write-Output 'PASS: explicit extra ACE removed, inheritance disabled, SYSTEM/Administrators grants present, contents preserved.'
} finally {
    if (Test-Path -LiteralPath $testFile) {
        & icacls.exe $testFile /grant ('*' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + ':F') | Out-Null
        Remove-Item -LiteralPath $testFile
    }
}
