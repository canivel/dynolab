# Maintainer build. End users receive the ZIP and do not install build tools.
param(
    [string]$OutputDirectory = "$env:LOCALAPPDATA\DynoBuild\dist",
    [string]$WorkDirectory = "$env:LOCALAPPDATA\DynoBuild\w-5bda51b",
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Build using native Windows PowerShell, not WSL or macOS.' }
function Check-Exit { if ($LASTEXITCODE -ne 0) { throw "Build command failed with exit code $LASTEXITCODE" } }
$revision = '5bda51bfbc62e64193221e639f6ad4e08767d760'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
function Canonical-Directory([string]$Path) {
    $absolute = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    New-Item -ItemType Directory -Force -Path $absolute | Out-Null
    return (Resolve-Path -LiteralPath $absolute).Path
}
$OutputDirectory = Canonical-Directory $OutputDirectory
$work = Canonical-Directory $WorkDirectory
if ($work.Length -gt 100) { throw 'Build cache path is too long. Choose a shorter WorkDirectory.' }
New-Item -ItemType Directory -Force $work | Out-Null
$source = Join-Path $work 'llama.cpp'
if (-not (Test-Path -LiteralPath "$source\.git")) {
    if ((Test-Path -LiteralPath $source) -and @(Get-ChildItem -LiteralPath $source -Force).Count) {
        throw 'Source cache is not a Git repository. Choose a new WorkDirectory; existing files were preserved.'
    }
    git init $source
    Check-Exit
}
git -C $source config core.longpaths true
Check-Exit
git -C $source fetch --depth 1 https://github.com/ggml-org/llama.cpp.git $revision
Check-Exit
git -C $source sparse-checkout set --no-cone '/*' '!/tools/ui/'
Check-Exit
git -C $source checkout --detach $revision
Check-Exit
$actualRevision = git -C $source rev-parse HEAD
Check-Exit
if ($actualRevision -ne $revision) { throw 'Source revision does not match the pinned runtime.' }
if (Test-Path -LiteralPath "$source\tools\ui") { throw 'Sparse checkout unexpectedly contains tools/ui. Choose a fresh WorkDirectory.' }
Write-Output "Prepared pinned source: $source ($actualRevision)"
if ($PrepareOnly) { return }
foreach ($tool in @('cmake', 'python')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing build tool: $tool. See worker/windows/README.md." }
}
cmake -S $source -B "$work\cuda" -G 'Visual Studio 17 2022' -A x64 -DGGML_RPC=ON -DGGML_CUDA=ON -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
Check-Exit
cmake --build "$work\cuda" --config Release --target ggml-rpc-server --parallel 4
Check-Exit
python -m venv "$work\venv"
Check-Exit
$python = "$work\venv\Scripts\python.exe"
& $python -m pip install 'pyinstaller==6.22.2' 'cryptography==50.0.1' 'ifaddr==0.2.0'
Check-Exit
$previousSkipCython = $env:SKIP_CYTHON
try {
    # The supported pure-Python implementation avoids optional native discovery DLLs.
    $env:SKIP_CYTHON = '1'
    & $python -m pip install --force-reinstall --no-deps --no-binary=zeroconf --no-cache-dir 'zeroconf==0.151.3'
    Check-Exit
} finally { $env:SKIP_CYTHON = $previousSkipCython }
& $python -m PyInstaller --noconfirm --clean --windowed --onedir --name DynoWorker --paths "$repo\src" --distpath "$OutputDirectory\app" --workpath "$work\pyinstaller" --specpath $work "$PSScriptRoot\entry.py"
Check-Exit
$app = "$OutputDirectory\app\DynoWorker"
$runtime = "$app\runtime"
New-Item -ItemType Directory -Force $runtime | Out-Null
Copy-Item "$work\cuda\bin\Release\*.dll" $runtime
Copy-Item "$work\cuda\bin\Release\ggml-rpc-server.exe" $runtime
# Bundle CUDA redistributables so the user only needs an NVIDIA driver.
if (-not $env:CUDA_PATH) { throw 'CUDA_PATH is missing. Install the CUDA toolkit before packaging.' }
foreach ($pattern in @('cudart64*.dll', 'cublas64*.dll', 'cublasLt64*.dll')) {
    $files = @(Get-ChildItem "$env:CUDA_PATH\bin" -Recurse -Filter $pattern)
    if ($files.Count -eq 0) { throw "Missing CUDA runtime: $pattern" }
    $files | Copy-Item -Destination $runtime -Force
}
# Include the MSVC redistributable DLLs from the maintainer's Visual Studio install.
if (-not $env:VCToolsRedistDir) { throw 'Use Developer PowerShell for VS 2022 (VCToolsRedistDir missing).' }
$crt = @(Get-ChildItem "$env:VCToolsRedistDir\x64\Microsoft.VC143.CRT\*.dll")
if ($crt.Count -eq 0) { throw 'Visual C++ runtime DLLs were not found.' }
$crt | Copy-Item -Destination $runtime -Force
$hashes = @{}
Get-ChildItem $runtime -File | ForEach-Object { $hashes[$_.Name] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower() }
@{revision=$revision; files=$hashes} | ConvertTo-Json -Depth 4 | Set-Content "$runtime\manifest.json" -Encoding ascii
Copy-Item "$PSScriptRoot\setup-lan.ps1" $app
Copy-Item "$PSScriptRoot\setup-discovery.ps1" $app
Copy-Item "$PSScriptRoot\README.md" $app
Copy-Item "$PSScriptRoot\PAIRING.md" $app
& $python "$PSScriptRoot\package-notices.py" $app
Check-Exit
Copy-Item "$repo\LICENSE" "$app\LICENSE-Dyno.txt"
Copy-Item "$source\LICENSE" "$app\LICENSE-llama.cpp.txt"
# A redistributable package must carry the CUDA license supplied by the toolkit.
$cudaLicense = Get-Item -LiteralPath "$env:CUDA_PATH\LICENSE" -ErrorAction SilentlyContinue
if (-not $cudaLicense) {
    $cudaLicense = Get-ChildItem $env:CUDA_PATH -Filter '*EULA*' -Recurse -File | Select-Object -First 1
}
if (-not $cudaLicense) { throw 'CUDA EULA not found. Include NVIDIA redistribution notices before distributing.' }
Copy-Item $cudaLicense.FullName "$app\LICENSE-NVIDIA.txt"
$zip = "$OutputDirectory\DynoWorker-windows-x64-preview.zip"
Compress-Archive -Path $app -DestinationPath $zip -Force
(Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() | Set-Content "$zip.sha256" -Encoding ascii
Write-Output "Preview package: $zip"
