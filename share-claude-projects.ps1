<#
.SYNOPSIS
  Share Claude Code folders (sessions by default) across VS Code profiles.

.DESCRIPTION
  A VS Code profile can point Claude Code at its own config dir through
  claudeCode.environmentVariables -> CLAUDE_CONFIG_DIR. This script finds
  those dirs (VS Code, VS Code Insiders, Cursor, VSCodium, plus any
  ~\.claude-* folder), merges the chosen sub-folders into one shared config
  dir, keeps the originals as <item>.bak-<timestamp>, and replaces them with
  directory junctions to the shared copy.

  Close every Claude conversation before -Share / -Unshare.

.EXAMPLE
  pwsh -File share-claude-projects.ps1 -Status                      # what is shared now
  pwsh -File share-claude-projects.ps1 -DryRun                      # preview sharing
  pwsh -File share-claude-projects.ps1                              # share 'projects'
  pwsh -File share-claude-projects.ps1 -Items projects,file-history # share more folders
  pwsh -File share-claude-projects.ps1 -ConfigDirs D:\cc-a,D:\cc-b  # only these dirs
  pwsh -File share-claude-projects.ps1 -Unshare                     # back to separate copies
  pwsh -File share-claude-projects.ps1 -RemoveBackups               # delete *.bak-* folders
#>
[CmdletBinding(DefaultParameterSetName = 'Share')]
param(
    [Parameter(ParameterSetName = 'Status')]  [switch]$Status,
    [Parameter(ParameterSetName = 'Unshare')] [switch]$Unshare,
    [Parameter(ParameterSetName = 'Clean')]   [switch]$RemoveBackups,

    # Config dirs to link; default: discovered from editor profiles.
    [string[]]$ConfigDirs,
    # Config dir that holds the real files; default: the Default profile's.
    [string]$SharedDir,
    # Sub-folders of each config dir to share.
    [string[]]$Items = @('projects'),

    [switch]$DryRun,
    # Skip the "claude.exe is running" check.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# 'pwsh -File' passes "a,b" as one string; split it ourselves.
$Items = $Items -split ',' | ForEach-Object Trim | Where-Object { $_ }
if ($ConfigDirs) { $ConfigDirs = $ConfigDirs -split ',' | ForEach-Object Trim | Where-Object { $_ } }
$home_ = $env:USERPROFILE

function Say($msg) { Write-Host ($(if ($DryRun) { '[dry-run] ' } else { '' }) + $msg) }

function Resolve-Dir([string]$p) {
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -match '^~') { $p = $home_ + $p.Substring(1) }
    [IO.Path]::GetFullPath($p).TrimEnd('\')
}

# CLAUDE_CONFIG_DIR from a settings.json (JSONC, so match instead of parse).
function Get-ConfigDir([string]$settings) {
    if (-not (Test-Path $settings)) { return $null }
    $m = [regex]::Match((Get-Content $settings -Raw),
         '\{[^{}]*"name"\s*:\s*"CLAUDE_CONFIG_DIR"[^{}]*\}')
    if (-not $m.Success) { return $null }
    $v = [regex]::Match($m.Value, '"value"\s*:\s*("(?:[^"\\]|\\.)*")')
    if ($v.Success) { Resolve-Dir (ConvertFrom-Json $v.Groups[1].Value) }
}

# --- Discover profiles -> config dirs -------------------------------------

$defaultDir = Join-Path $home_ '.claude'
$found = [System.Collections.Generic.List[object]]::new()

if ($ConfigDirs) {
    foreach ($d in $ConfigDirs) { $found.Add([pscustomobject]@{ Name = Split-Path $d -Leaf; Dir = Resolve-Dir $d }) }
} else {
    foreach ($editor in 'Code', 'Code - Insiders', 'Cursor', 'VSCodium') {
        $user = Join-Path $env:APPDATA "$editor\User"
        if (-not (Test-Path $user)) { continue }

        $def = Get-ConfigDir (Join-Path $user 'settings.json')
        $found.Add([pscustomobject]@{ Name = "$editor/Default"; Dir = $(if ($def) { $def } else { $defaultDir }) })

        $names = @{}
        $storage = Join-Path $user 'globalStorage\storage.json'
        if (Test-Path $storage) {
            foreach ($p in (Get-Content $storage -Raw | ConvertFrom-Json).userDataProfiles) { $names[$p.location] = $p.name }
        }
        foreach ($s in Get-ChildItem (Join-Path $user 'profiles') -Filter settings.json -Recurse -Depth 1 -ErrorAction SilentlyContinue) {
            $loc = $s.Directory.Name
            $dir = Get-ConfigDir $s.FullName
            $name = if ($names[$loc]) { $names[$loc] } else { $loc }
            $found.Add([pscustomobject]@{ Name = "$editor/$name"; Dir = $(if ($dir) { $dir } else { $defaultDir }) })
        }
    }
    # Config dirs no profile points at (yet).
    foreach ($d in Get-ChildItem $home_ -Directory -Filter '.claude*' -Force) {
        $dir = Resolve-Dir $d.FullName
        if ($found.Dir -notcontains $dir) { $found.Add([pscustomobject]@{ Name = '(no profile)'; Dir = $dir }) }
    }
}

$shared = if ($SharedDir) { Resolve-Dir $SharedDir } else { Resolve-Dir $defaultDir }
$dirs = $found | Group-Object Dir | ForEach-Object {
    [pscustomobject]@{ Dir = $_.Name; Names = ($_.Group.Name | Select-Object -Unique) -join ', ' }
}
$targets = $dirs | Where-Object { $_.Dir -ne $shared }

function Get-State([string]$dir, [string]$item) {
    $path = Join-Path $dir $item
    if (-not (Test-Path $path)) { return 'missing' }
    $i = Get-Item $path -Force
    if (-not $i.LinkType) { return 'separate' }
    $t = Resolve-Dir ([string]$i.Target)
    if ($t -eq (Resolve-Dir (Join-Path $shared $item))) { 'shared' } else { "linked -> $t" }
}

function Assert-NoClaude {
    $running = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
    if (-not $running -or $Force) { return }
    $msg = "claude.exe is still running (PID $($running.Id -join ', ')). Close all Claude conversations first, or pass -Force."
    if ($DryRun) { Write-Warning $msg } else { throw $msg }
}

# Copy every file of $src into $dst; never overwrite a different file.
function Merge-Folder([string]$src, [string]$dst, [string]$tag) {
    $copied = 0; $same = 0; $conflict = 0
    Get-ChildItem $src -Recurse -File -Force | ForEach-Object {
        $rel  = $_.FullName.Substring($src.Length).TrimStart('\')
        $dest = Join-Path $dst $rel
        if (-not (Test-Path $dest)) {
            if (-not $DryRun) {
                New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
                Copy-Item $_.FullName $dest
            }
            $copied++
        } elseif ((Get-FileHash $_.FullName).Hash -eq (Get-FileHash $dest).Hash) {
            $same++
        } else {
            $alt = [IO.Path]::Combine((Split-Path $dest),
                   [IO.Path]::GetFileNameWithoutExtension($dest) + ".from$tag" + [IO.Path]::GetExtension($dest))
            Say "  Conflict: $rel -> kept shared copy, saved this one as $(Split-Path $alt -Leaf)"
            if (-not $DryRun) { Copy-Item $_.FullName $alt }
            $conflict++
        }
    }
    Say "  Copied $copied, identical $same, conflicts $conflict"
}

# --- Actions ---------------------------------------------------------------

switch ($PSCmdlet.ParameterSetName) {

    'Status' {
        Write-Host "Shared dir: $shared"
        foreach ($d in $dirs) {
            Write-Host "`n$($d.Dir)  [$($d.Names)]"
            foreach ($item in $Items) {
                $state = if ($d.Dir -eq $shared) { 'shared (source)' } else { Get-State $d.Dir $item }
                $path = Join-Path $d.Dir $item
                $n = if (Test-Path $path) { (Get-ChildItem $path -Recurse -Depth 1 -Filter *.jsonl -File -ErrorAction SilentlyContinue).Count } else { 0 }
                Write-Host ("  {0,-14} {1,-30} {2} sessions" -f $item, $state, $n)
            }
        }
    }

    'Share' {
        Assert-NoClaude
        foreach ($item in $Items) {
            $src = Join-Path $shared $item
            if (-not (Test-Path $src)) {
                Say "Create shared folder $src"
                if (-not $DryRun) { New-Item -ItemType Directory -Path $src -Force | Out-Null }
            }
            foreach ($d in $targets) {
                $path = Join-Path $d.Dir $item
                Write-Host "== $path  [$($d.Names)]"
                $state = Get-State $d.Dir $item
                if ($state -eq 'shared') { Say '  Already shared; skip'; continue }
                if ($state -like 'linked*') { Write-Warning "  $state; leaving it alone"; continue }
                if ($state -eq 'separate') {
                    Merge-Folder $path $src (Split-Path $d.Dir -Leaf)
                    Say "  Rename $item -> $item.bak-$stamp"
                    if (-not $DryRun) { Rename-Item $path "$item.bak-$stamp" }
                }
                Say "  Create junction -> $src"
                if (-not $DryRun) {
                    New-Item -ItemType Directory -Path $d.Dir -Force | Out-Null
                    New-Item -ItemType Junction -Path $path -Target $src | Out-Null
                }
            }
        }
        Write-Host 'Done. Check each profile, then run -RemoveBackups when satisfied.'
    }

    'Unshare' {
        Assert-NoClaude
        foreach ($item in $Items) {
            $src = Join-Path $shared $item
            foreach ($d in $targets) {
                $path = Join-Path $d.Dir $item
                if ((Get-State $d.Dir $item) -ne 'shared') { continue }
                Write-Host "== $path  [$($d.Names)]"
                Say "  Remove junction, copy current shared contents into a separate folder"
                if (-not $DryRun) {
                    cmd /c rmdir "$path"    # removes the link only, not the shared files
                    New-Item -ItemType Directory -Path $path | Out-Null
                    Copy-Item (Join-Path $src '*') $path -Recurse -Force
                }
            }
        }
        Write-Host 'Done. Each profile now has its own copy again.'
    }

    'Clean' {
        foreach ($d in $targets) {
            foreach ($item in $Items) {
                foreach ($b in Get-ChildItem $d.Dir -Directory -Force -Filter "$item.bak-*" -ErrorAction SilentlyContinue) {
                    Say "Delete $($b.FullName)"
                    if ($DryRun) { continue }
                    if ($b.LinkType) { cmd /c rmdir "$($b.FullName)" } else { Remove-Item $b.FullName -Recurse -Force }
                }
            }
        }
    }
}
