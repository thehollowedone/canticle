param(
    [string]$Lsp,
    [string]$Rojo,
    [string]$Defs
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lspVersion = '1.68.1'
$definitionsHash = 'a0027362f872d231c1c4bbea6b2d5d561b0a4ea7e82458ea8a5f862cef8938aa'
$toolsBin = Join-Path $env:USERPROFILE '.rokit\bin'

function Resolve-Tool([string]$Name, [string]$Override) {
    if ($Override) {
        return $Override
    }

    $extension = if ($env:OS -eq 'Windows_NT') { '.exe' } else { '' }
    $rokitTool = Join-Path $toolsBin ($Name + $extension)
    if (Test-Path -LiteralPath $rokitTool -PathType Leaf) {
        return $rokitTool
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "$Name is missing; install the tools from rokit.toml"
}

function Assert-Definitions([string]$Path) {
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $definitionsHash) {
        throw 'Roblox definitions failed SHA-256 verification'
    }
}

$lspPath = Resolve-Tool 'luau-lsp' $Lsp
$rojoPath = Resolve-Tool 'rojo' $Rojo
$actualVersion = (& $lspPath --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualVersion -ne $lspVersion) {
    throw "Expected luau-lsp $lspVersion, got $actualVersion"
}

if (-not $Defs) {
    $definitionsDirectory = Join-Path $root '.tools'
    $Defs = Join-Path $definitionsDirectory "globalTypes-$lspVersion.d.luau"
    if (-not (Test-Path -LiteralPath $Defs -PathType Leaf)) {
        $null = New-Item -ItemType Directory -Path $definitionsDirectory -Force
        $uri = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/$lspVersion/scripts/globalTypes.d.luau"
        Invoke-WebRequest -Uri $uri -OutFile $Defs
    }
}
Assert-Definitions $Defs

$sourceMap = Join-Path ([System.IO.Path]::GetTempPath()) ("canticle-typecheck-" + [guid]::NewGuid().ToString('N') + '.json')
try {
    & $rojoPath sourcemap default.project.json --include-non-scripts -o $sourceMap
    if ($LASTEXITCODE -ne 0) {
        throw 'Rojo failed to generate the type-analysis sourcemap'
    }

    $failed = $false
    foreach ($allFlags in @($false, $true)) {
        foreach ($solverV2 in @($true, $false)) {
            $profile = if ($allFlags) { 'all flags' } else { 'default flags' }
            $solver = if ($solverV2) { 'V2' } else { 'V1' }
            Write-Host "Luau Solver $solver ($profile)"
            $arguments = @('analyze')
            if (-not $allFlags) {
                $arguments += '--no-flags-enabled'
            }
            $arguments += @(
                "--flag:LuauSolverV2=$($solverV2.ToString().ToLowerInvariant())",
                '--sourcemap', $sourceMap,
                '--defs', (Resolve-Path -LiteralPath $Defs).Path,
                '--base-luaurc', (Join-Path $root '.luaurc'),
                '--platform', 'roblox',
                (Join-Path $root 'src'),
                (Join-Path $root 'tools\ClientCodecGenerator.luau'),
                (Join-Path $root 'tools\NativeCodecGenerator.luau')
            )
            & $lspPath @arguments
            if ($LASTEXITCODE -ne 0) {
                $failed = $true
            }
        }
    }

    if ($failed) {
        Write-Error 'Type analysis FAILED'
        exit 1
    }
    Write-Host 'All runtime type checks passed'
} finally {
    Remove-Item -LiteralPath $sourceMap -Force -ErrorAction SilentlyContinue
}
