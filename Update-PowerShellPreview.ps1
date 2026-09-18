#requires -Version 7.4

<#
.SYNOPSIS
    Updates PowerShell Preview to the latest version on Windows, Linux, and macOS.

.DESCRIPTION
    Reads the current preview release tag from the PowerShell metadata file, picks a
    matching asset from the official GitHub release, verifies its SHA256 hash against
    hashes.sha256, and installs it with the native package mechanism:
    msi/msixbundle on Windows, apt/dnf/rpm/tarball on Linux, pkg/brew on macOS.

.EXAMPLE
    ./Update-PowerShellPreview.ps1

.EXAMPLE
    ./Update-PowerShellPreview.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$script:LogPath = Join-Path ([System.IO.Path]::GetTempPath()) 'PowerShellPreviewUpdate.log'

function Write-Log {
    param([string]$Message)
    $entry = '{0} - {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $script:LogPath -Value $entry -WhatIf:$false -Confirm:$false
    Write-Host $entry
}

function Get-LatestPreviewRelease {
    $retry = @{ MaximumRetryCount = 3; RetryIntervalSec = 2 }
    $metadata = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json' @retry
    $tag = $metadata.PreviewReleaseTag
    if ($tag -notmatch '^v(\d+\.\d+\.\d+)(?:-(preview|rc)\.(\d+))?$') {
        throw "Unable to parse PreviewReleaseTag: $tag"
    }
    $fullVersion = $Matches[1]
    if ($Matches[2]) {
        $fullVersion = '{0}-{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/tags/$tag" @retry
    [pscustomobject]@{
        Tag     = $tag
        Version = [System.Management.Automation.SemanticVersion]::new($fullVersion)
        Release = $release
    }
}

function Get-Platform {
    $os = if ($IsWindows) { 'win' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'osx' } else { throw 'Unsupported operating system. This script requires PowerShell 7+.' }
    $cpu = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $arch = switch ("$cpu") {
        'Arm64' { 'arm64' }
        'Arm'   { 'arm32' }
        'X64'   { 'x64' }
        'X86'   { 'x86' }
        default { throw "Unsupported CPU architecture: $cpu" }
    }
    # Asset kinds are tried in this order; the choice depends on the system's
    # package manager, not on which assets the release happens to contain.
    $kindPreference = @(
        switch ($os) {
            'win' { 'msi'; 'msix' }
            'osx' { 'pkg' }
            'linux' {
                if ((Get-Command apt-get -ErrorAction SilentlyContinue) -or (Get-Command dpkg -ErrorAction SilentlyContinue)) {
                    'deb'
                }
                elseif (Get-Command dnf, yum, zypper, rpm -ErrorAction SilentlyContinue) {
                    'rpm'
                }
                'targz'
            }
        }
    )
    [pscustomobject]@{ Os = $os; Arch = $arch; KindPreference = $kindPreference }
}

function Select-ReleaseAsset {
    param($Release, $Platform)

    $os = $Platform.Os
    $arch = $Platform.Arch
    $assets = @($Release.assets)
    $pkgArch = switch ($arch) { 'x64' { 'amd64|x86_64' } 'arm64' { 'arm64|aarch64' } default { $null } }

    # RPMs ship in two flavors: 'rh' targets the RHEL family, 'cm' is the generic
    # build. Pick by the running distro, keep the other flavor as fallback.
    $rpmFlavors = @('cm', 'rh')
    if ($os -eq 'linux' -and (Test-Path '/etc/os-release')) {
        $osRelease = Get-Content -Path '/etc/os-release' -Raw
        if ($osRelease -match '(?m)^ID(?:_LIKE)?="?[^\r\n"]*\b(rhel|fedora)\b') {
            $rpmFlavors = @('rh', 'cm')
        }
    }

    $matchers = foreach ($kind in $Platform.KindPreference) {
        switch ("$os/$kind") {
            'win/msi'     { @{ Kind = 'msi';  Pattern = "^PowerShell-.+-win-$arch\.msi$" } }
            'win/msix'    { @{ Kind = 'msix'; Pattern = '^PowerShellPreview-.+\.msixbundle$' } }
            'linux/deb'   { if ($pkgArch) { @{ Kind = 'deb'; Pattern = "^powershell-preview_.+_($pkgArch)\.deb$" } } }
            'linux/rpm'   {
                if ($pkgArch) {
                    foreach ($flavor in $rpmFlavors) {
                        @{ Kind = 'rpm'; Pattern = "^powershell-preview-.+\.$flavor\.($pkgArch)\.rpm$" }
                    }
                }
            }
            'linux/targz' { @{ Kind = 'targz'; Pattern = "^powershell-.+-linux-$arch\.tar\.gz$" } }
            'osx/pkg'     { @{ Kind = 'pkg';  Pattern = "^powershell-.+-osx-$arch\.pkg$" } }
        }
    }

    foreach ($matcher in $matchers) {
        if (-not $matcher) { continue }
        $asset = $assets | Where-Object { $_.name -match $matcher.Pattern } | Select-Object -First 1
        if ($asset) {
            return [pscustomobject]@{ Kind = $matcher.Kind; Name = $asset.name; Url = $asset.browser_download_url }
        }
    }
    throw "No installer asset found for ${os}-${arch}. Available assets: $($assets.name -join ', ')"
}

function Get-ReleaseHashes {
    param($Release, [string]$WorkDir)
    $hashAsset = $Release.assets | Where-Object { $_.name -eq 'hashes.sha256' } | Select-Object -First 1
    if (-not $hashAsset) {
        throw 'hashes.sha256 asset is missing from the release'
    }
    # The file ships as UTF-16LE with BOM, so it must go through a real file read
    # instead of Invoke-RestMethod's in-memory string decoding.
    $hashFile = Join-Path $WorkDir $hashAsset.name
    Invoke-WebRequest -Uri $hashAsset.browser_download_url -OutFile $hashFile -MaximumRetryCount 3 -RetryIntervalSec 2
    Get-Content -Path $hashFile -Raw
}

function Test-InstallerHash {
    param([string]$FilePath, [string]$AssetName, [string]$HashesContent)
    # Match the exact filename token (hashes use sha256sum format: "<hash> *<name>")
    # so a name that is a substring of another asset can never verify wrongly.
    $entry = $HashesContent -split "\r?\n" |
        Where-Object {
            $tokens = $_.Trim() -split '\s+'
            $tokens.Count -ge 2 -and $tokens[1].TrimStart('*') -eq $AssetName
        } |
        Select-Object -First 1
    if (-not $entry) {
        throw "No hash entry for '$AssetName' in hashes.sha256"
    }
    $expected = ($entry.Trim() -split '\s+')[0]
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
    if (-not [string]::Equals($actual, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "SHA256 mismatch for '$AssetName' (expected $expected, got $actual)"
    }
}

function Invoke-VerifiedDownload {
    param($Asset, $Release, [string]$WorkDir)
    $installerPath = Join-Path $WorkDir $Asset.Name
    Write-Log "Downloading installer from: $($Asset.Url)"
    Invoke-WebRequest -Uri $Asset.Url -OutFile $installerPath -MaximumRetryCount 3 -RetryIntervalSec 5
    $hashes = Get-ReleaseHashes -Release $Release -WorkDir $WorkDir
    Test-InstallerHash -FilePath $installerPath -AssetName $Asset.Name -HashesContent $hashes
    Write-Log "Installer downloaded and SHA256 verified: $installerPath"
    $installerPath
}

function Invoke-NativeCommand {
    param([Parameter(Mandatory)][string[]]$Argv)
    Write-Log "Running: $($Argv -join ' ')"
    $exe = $Argv[0]
    $rest = if ($Argv.Count -gt 1) { $Argv[1..($Argv.Count - 1)] } else { @() }
    # Capture stdout/stderr so nothing leaks into the caller's success stream;
    # the boolean result of Update-PowerShellPreview must stay the only object there.
    $output = & $exe @rest 2>&1
    foreach ($line in $output) { Write-Host "$line" }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $($Argv -join ' ')"
    }
}

function Get-RootCommandPrefix {
    # Returns $null when already root, otherwise 'sudo'. A scalar return avoids
    # PowerShell's single-element array unwrapping breaking concatenation upstream.
    if ((& id -u) -eq 0) { return $null }
    if (Get-Command sudo -ErrorAction SilentlyContinue) { return 'sudo' }
    throw 'Root privileges are required and sudo is not available. Run the script as root.'
}

function Invoke-Privileged {
    param([Parameter(Mandatory)][string[]]$Argv)
    $rootCmd = Get-RootCommandPrefix
    $full = if ($rootCmd) { @($rootCmd) + $Argv } else { $Argv }
    Invoke-NativeCommand -Argv $full
}

function Test-WindowsAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    [System.Security.Principal.WindowsPrincipal]::new($identity).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-WindowsPackage {
    param([string]$Kind, [string]$InstallerPath)
    if ($Kind -eq 'msi') {
        if (-not (Test-WindowsAdmin)) {
            throw 'Administrator privileges are required for the MSI installation. Run the script from an elevated PowerShell.'
        }
        $msiLog = Join-Path ([System.IO.Path]::GetTempPath()) 'PowerShellPreviewInstall.log'
        Write-Log 'Running silent MSI installation. Close other PowerShell sessions to avoid a forced reboot.'
        $process = Start-Process msiexec.exe -ArgumentList "/i `"$InstallerPath`" /qn /norestart /l*v `"$msiLog`"" -Wait -PassThru
        if ($process.ExitCode -in 3010, 1641) {
            Write-Log 'A reboot is required to complete the installation.'
        }
        elseif ($process.ExitCode -ne 0) {
            throw "Installation failed with exit code $($process.ExitCode). MSI log: $msiLog"
        }
    }
    elseif ($Kind -eq 'msix') {
        if (-not (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) {
            Import-Module Appx -UseWindowsPowerShell
        }
        if (Test-Path "$env:ProgramFiles\PowerShell\7-preview\pwsh.exe") {
            Write-Log 'WARNING: an MSI-installed PowerShell Preview exists in Program Files. Previews no longer ship MSI, so this installs the MSIX copy side-by-side and the MSI install stays untouched.'
        }
        Write-Log 'Installing msixbundle for the current user'
        try {
            Add-AppxPackage -Path $InstallerPath
        }
        catch {
            throw "MSIX installation failed: $($_.Exception.Message). If the package is in use, close other pwsh-preview sessions or run this script from a stable PowerShell install."
        }
    }
    else {
        throw "Unsupported Windows installer kind: $Kind"
    }
}

function Install-MacOsPackage {
    param([string]$Kind, [string]$InstallerPath)
    if ($Kind -ne 'pkg') {
        throw "Unsupported macOS installer kind: $Kind"
    }
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        & brew list --cask powershell-preview *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'PowerShell Preview is managed by Homebrew, upgrading the cask'
            Invoke-NativeCommand -Argv @('brew', 'upgrade', '--cask', 'powershell-preview')
            return
        }
        & brew list --formula powershell-preview *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'PowerShell is managed by Homebrew formula, upgrading it'
            Invoke-NativeCommand -Argv @('brew', 'upgrade', 'powershell-preview')
            return
        }
        Write-Log 'Homebrew found, but powershell-preview is not managed by it; using the pkg installer'
    }
    Invoke-Privileged -Argv @('installer', '-pkg', $InstallerPath, '-target', '/')
}

function Install-LinuxPackage {
    param([string]$Kind, [string]$InstallerPath)
    switch ($Kind) {
        'deb' {
            if (Get-Command apt-get -ErrorAction SilentlyContinue) {
                Invoke-Privileged -Argv @('apt-get', 'install', '-y', $InstallerPath)
            }
            else {
                Invoke-Privileged -Argv @('dpkg', '-i', $InstallerPath)
            }
        }
        'rpm' {
            $manager = foreach ($candidate in 'dnf', 'yum', 'zypper', 'rpm') {
                if (Get-Command $candidate -ErrorAction SilentlyContinue) { $candidate; break }
            }
            if (-not $manager) {
                throw 'Neither dnf, yum, zypper nor rpm is available to install the rpm package.'
            }
            $managerArgs = switch ($manager) {
                'dnf'    { @('install', '-y', $InstallerPath) }
                'yum'    { @('install', '-y', $InstallerPath) }
                'zypper' { @('--non-interactive', 'install', $InstallerPath) }
                'rpm'    { @('-Uvh', $InstallerPath) }
            }
            Invoke-Privileged -Argv (@($manager) + $managerArgs)
        }
        default { throw "Unsupported Linux installer kind: $Kind" }
    }
}

function Install-LinuxTarball {
    param([string]$InstallerPath, [string]$WorkDir)
    $extractDir = Join-Path $WorkDir 'extract'
    New-Item -ItemType Directory -Path $extractDir | Out-Null
    Invoke-NativeCommand -Argv @('tar', '-xzf', $InstallerPath, '-C', $extractDir)

    $target = '/opt/microsoft/powershell-preview'
    if (Test-Path $target) {
        Invoke-Privileged -Argv @('rm', '-rf', $target)
    }
    Invoke-Privileged -Argv @('mkdir', '-p', $target)
    Invoke-Privileged -Argv @('cp', '-a', "$extractDir/.", $target)

    $link = '/usr/local/bin/pwsh-preview'
    Invoke-Privileged -Argv @('ln', '-sfn', (Join-Path $target 'pwsh'), $link)
}

function Update-PowerShellPreview {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('pwsh-updater-' + [System.IO.Path]::GetRandomFileName())

    try {
        Write-Log 'Starting PowerShell Preview update check'
        $currentVersion = $PSVersionTable.PSVersion
        Write-Log "Current version: $currentVersion"

        $latest = Get-LatestPreviewRelease
        Write-Log "Latest preview release: $($latest.Version) ($($latest.Tag))"

        if ($currentVersion -ge $latest.Version) {
            Write-Log 'PowerShell is already up to date.'
            return $true
        }

        $platform = Get-Platform
        $asset = Select-ReleaseAsset -Release $latest.Release -Platform $platform
        Write-Log "Selected installer asset: $($asset.Name) ($($asset.Kind))"

        # Fail fast on missing privileges before spending time on the download.
        # Skipped under -WhatIf so a dry run always reports cleanly.
        if (-not $WhatIfPreference) {
            if ($platform.Os -eq 'win' -and $asset.Kind -eq 'msi' -and -not (Test-WindowsAdmin)) {
                throw 'Administrator privileges are required for the MSI installation. Run the script from an elevated PowerShell.'
            }
            if ($platform.Os -eq 'linux') {
                $null = Get-RootCommandPrefix
            }
        }

        # Stop before downloading anything in WhatIf mode; cmdlets below must run
        # unconstrained because they only prepare files inside the temp work dir.
        if (-not $PSCmdlet.ShouldProcess("PowerShell Preview $($latest.Version)", "Install $($asset.Kind) package")) {
            return $true
        }

        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $installerPath = Invoke-VerifiedDownload -Asset $asset -Release $latest.Release -WorkDir $workDir

        $null = switch ($asset.Kind) {
            'msi'   { Install-WindowsPackage -Kind 'msi' -InstallerPath $installerPath }
            'msix'  { Install-WindowsPackage -Kind 'msix' -InstallerPath $installerPath }
            'deb'   { Install-LinuxPackage -Kind 'deb' -InstallerPath $installerPath }
            'rpm'   { Install-LinuxPackage -Kind 'rpm' -InstallerPath $installerPath }
            'targz' { Install-LinuxTarball -InstallerPath $installerPath -WorkDir $workDir }
            'pkg'   { Install-MacOsPackage -Kind 'pkg' -InstallerPath $installerPath }
            default { throw "Unsupported installer kind: $($asset.Kind)" }
        }

        Write-Log "PowerShell has been updated to version $($latest.Version)."
        Write-Log 'Please restart your PowerShell session to use the new version.'
        return $true
    }
    catch {
        Write-Log "Error occurred: $($_.Exception.Message)"
        Write-Error $_ -ErrorAction Continue
        return $false
    }
    finally {
        if (Test-Path $workDir) {
            Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "Update process completed. Log file: $script:LogPath"
    }
}

if (-not (Update-PowerShellPreview @PSBoundParameters)) {
    exit 1
}
