# PowerShell Preview Updater

This script automatically updates PowerShell Preview to the latest version on Windows, Linux, and macOS, supporting various hardware architectures.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Usage](#usage)
4. [System-Specific Instructions](#system-specific-instructions)
   - [Windows](#windows)
   - [Linux](#linux)
   - [macOS](#macos)
5. [Hardware Architecture Support](#hardware-architecture-support)
6. [Troubleshooting](#troubleshooting)

## Prerequisites

- PowerShell 6.0 or later installed on your system
- Internet connection
- Administrator/root privileges

## Installation

1. Download the `Update-PowerShellPreview.ps1` script.
2. Save it to a location on your computer (e.g., `Documents` folder on Windows, `Home` directory on Linux/macOS).

## Usage

To run the script:

1. Open PowerShell (Windows) or Terminal (Linux/macOS).
2. Navigate to the directory containing the script:
   ```powershell
   cd path/to/script/directory
   ```
3. Run the script:
   ```powershell
   ./Update-PowerShellPreview.ps1
   ```

## System-Specific Instructions

### Windows

1. Right-click on PowerShell and select "Run as Administrator".
2. You may need to change the execution policy:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
3. Run the script as shown in the [Usage](#usage) section.

### Linux

1. Ensure PowerShell is installed. If not, [install it from Microsoft's instructions](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-core-on-linux).
2. Open Terminal.
3. You may need to make the script executable:
   ```bash
   chmod +x ./Update-PowerShellPreview.ps1
   ```
4. Run the script with sudo:
   ```bash
   sudo pwsh ./Update-PowerShellPreview.ps1
   ```

### macOS

1. Ensure PowerShell is installed. If not, [install it from Microsoft's instructions](https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-core-on-macos).
2. Open Terminal.
3. You may need to make the script executable:
   ```bash
   chmod +x ./Update-PowerShellPreview.ps1
   ```
4. Run the script with sudo:
   ```bash
   sudo pwsh ./Update-PowerShellPreview.ps1
   ```

## Hardware Architecture Support

This script supports the following architectures:

- x64 (64-bit)
- x86 (32-bit)
- ARM64
- ARM32

The script automatically detects your system's architecture and downloads the appropriate version.

## Troubleshooting

1. **Script won't run due to execution policy**
   - On Windows, run:
     ```powershell
     Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
     ```

2. **Permission denied error**
   - Ensure you're running PowerShell as Administrator (Windows) or using sudo (Linux/macOS).

3. **Download fails**
   - Check your internet connection.
   - Verify that the PowerShell GitHub repository is accessible from your network.

4. **Installation fails**
   - On Windows, ensure you have the necessary permissions to install software.
   - On Linux/macOS, make sure you have sudo privileges.

5. **Unsupported OS error**
   - Verify that you're running a supported operating system (Windows, Linux, or macOS).

6. **Log file for debugging**
   - Check the log file created in your temp directory for more detailed error information.

If you encounter any other issues, please check the PowerShell GitHub repository for known issues or file a new issue if necessary.
