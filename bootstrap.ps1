#Requires -Version 5.1
<#
    Bootstrap a Windows machine. Download and INSPECT before running:

      $env:DOTFILES_REPO = 'https://github.com/<user>/dotfiles.git'
      $env:BW_EMAIL      = 'you@example.com'
      irm https://raw.githubusercontent.com/<user>/dotfiles/v1.0.0/bootstrap.ps1 -OutFile $env:TEMP\b.ps1
      & $env:TEMP\b.ps1

    No identity is hardcoded here on purpose: this file is committed, and a
    repo should never carry PII.
#>
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$Repo = $env:DOTFILES_REPO
if (-not $Repo) { throw "Set `$env:DOTFILES_REPO, e.g. https://github.com/<user>/dotfiles.git" }

$BwEmail = $env:BW_EMAIL
if (-not $BwEmail) { $BwEmail = Read-Host 'Bitwarden account email' }
if (-not $BwEmail) { throw 'BW_EMAIL is required' }

function Log($m) { Write-Host "==> $m" -ForegroundColor Cyan }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget missing. Install 'App Installer' from the Microsoft Store, then re-run."
}

Log 'Installing prerequisites'
foreach ($id in @('Git.Git','twpayne.chezmoi','FiloSottile.age','GitHub.cli','Microsoft.PowerShell')) {
    winget install --id $id -e --source winget `
        --accept-package-agreements --accept-source-agreements --silent
}

if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Log 'Installing scoop (user-space, no admin)'
    Invoke-RestMethod get.scoop.sh | Invoke-Expression
}
scoop install bitwarden-cli gitleaks

# rbw is cargo-only on Windows and its agent is unix-socket shaped: use bw.
Log 'Unlocking Bitwarden'
bw config server https://vault.bitwarden.com | Out-Null
if ((bw status | ConvertFrom-Json).status -eq 'unauthenticated') { bw login $BwEmail }
$env:BW_SESSION = (bw unlock --raw)

$cfg = "$env:USERPROFILE\.config\chezmoi"
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
if (-not (Test-Path "$cfg\key.txt")) {
    Log 'Fetching age identity from Bitwarden'
    try {
        bw get password chezmoi-age-key | Set-Content "$cfg\key.txt" -NoNewline
        icacls "$cfg\key.txt" /inheritance:r /grant:r "$env:USERDOMAIN\${env:USERNAME}:(F)" | Out-Null
    } catch {
        Remove-Item "$cfg\key.txt" -ErrorAction SilentlyContinue
        Log "WARNING: vault item 'chezmoi-age-key' not found; encrypted files will fail"
    }
}

$key = "$env:USERPROFILE\.ssh\id_ed25519_personal"
if (-not (Test-Path $key)) {
    Log 'Generating a per-machine SSH key'
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh" | Out-Null
    ssh-keygen -t ed25519 -C "personal@$env:COMPUTERNAME-$(Get-Date -Format yyyyMM)" -f $key -N '""'
    Log 'Add this key to GitHub:'
    Get-Content "$key.pub"
}

gh auth status 2>$null; if ($LASTEXITCODE -ne 0) { gh auth login }

Log 'Applying dotfiles'
chezmoi init --apply $Repo

Remove-Item Env:\BW_SESSION -ErrorAction SilentlyContinue
bw lock
Log 'Done. Restart PowerShell.'
