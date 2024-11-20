function Update-PowerShellPreview {
    $logFile = Join-Path $env:TEMP "PowerShellPreviewUpdate.log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    function Log-Message {
        param([string]$message)
        $logEntry = "$timestamp - $message"
        Add-Content -Path $logFile -Value $logEntry
        Write-Host $logEntry
    }

    try {
        Log-Message "Starting PowerShell Preview update check"
        $currentVersion = $PSVersionTable.PSVersion
        Log-Message "Current version: $currentVersion"

        Log-Message "Fetching metadata from GitHub"
        $metaData = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json'
        Log-Message "Raw PreviewReleaseTag: $($metaData.PreviewReleaseTag)"

        # Updated regex pattern to handle RC versions
        if ($metaData.PreviewReleaseTag -match 'v(\d+\.\d+\.\d+)(?:-preview\.(\d+)|-(rc)\.(\d+))?') {
            $baseVersion = $matches[1]
            $isRC = $matches[3] -eq 'rc'
            $buildNumber = if ($isRC) { $matches[4] } else { $matches[2] }
            
            # Construct version string based on whether it's RC or preview
            $versionString = if ($isRC) {
                "$baseVersion-rc.$buildNumber"
            } else {
                $baseVersion
            }
            
            $latestPreviewVersion = [System.Version]::new($baseVersion)
            Log-Message "Parsed latest version: $versionString"
        } else {
            throw "Unable to parse version number from PreviewReleaseTag: $($metaData.PreviewReleaseTag)"
        }

        if ($currentVersion -lt $latestPreviewVersion -or 
            ($currentVersion -eq $latestPreviewVersion -and $PSVersionTable.GitCommitId -notmatch "(?:preview\.$buildNumber|rc\.$buildNumber)")) {
            Log-Message "A new version is available. Proceeding with update."

            # Determine OS and architecture
            $os = if ($IsWindows) { "win" } elseif ($IsLinux) { "linux" } elseif ($IsMacOS) { "osx" } else { throw "Unsupported operating system" }
            $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { "arm64" } 
                    elseif ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm) { "arm32" }
                    elseif ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::X64) { "x64" }
                    else { "x86" }

            $fileExtension = if ($IsWindows) { "msi" } elseif ($IsLinux) { "tar.gz" } elseif ($IsMacOS) { "pkg" } else { throw "Unsupported operating system" }
            
            # Updated download URL construction to include RC version in filename when applicable
            $downloadUrl = "https://github.com/PowerShell/PowerShell/releases/download/$($metaData.PreviewReleaseTag)/PowerShell-$versionString-$os-$arch.$fileExtension"
            $installerPath = Join-Path $env:TEMP "PowerShell-$versionString-$os-$arch.$fileExtension"

            Log-Message "Downloading installer from: $downloadUrl"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath
            Log-Message "Installer downloaded to: $installerPath"

            Log-Message "Starting installation process"
            if ($IsWindows) {
                $installProcess = Start-Process msiexec.exe -ArgumentList "/i `"$installerPath`" /qn" -Wait -PassThru
                if ($installProcess.ExitCode -eq 0) {
                    Log-Message "Installation completed successfully"
                } else {
                    throw "Installation failed with exit code: $($installProcess.ExitCode)"
                }
            } elseif ($IsLinux) {
                # For Linux, we'll extract the tar.gz and use the install script
                $extractPath = Join-Path $env:TEMP "PowerShellPreview"
                New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
                tar -xzf $installerPath -C $extractPath
                $installScript = Join-Path $extractPath "install-powershell.sh"
                chmod +x $installScript
                sudo $installScript
                Log-Message "Installation script executed"
            } elseif ($IsMacOS) {
                # For macOS, we'll use installer command
                sudo installer -pkg $installerPath -target /
                Log-Message "Installation completed"
            }

            Log-Message "Cleaning up temporary files"
            Remove-Item $installerPath -Force
            if ($IsLinux) {
                Remove-Item $extractPath -Recurse -Force
            }
            Log-Message "Temporary files removed"

            Log-Message "PowerShell has been updated to version $versionString"
            Log-Message "Please restart your PowerShell session to use the new version."
        } else {
            Log-Message "PowerShell is already up to date."
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Log-Message "Error occurred: $errorMessage"
        Write-Error $errorMessage
    }
    finally {
        Log-Message "Update process completed. Log file: $logFile"
    }
}

Update-PowerShellPreview