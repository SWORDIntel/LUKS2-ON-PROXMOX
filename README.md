# Proxmox VE Advanced Installer with ZFS on LUKS

A customizable, robust, and comprehensive installer script for setting up Proxmox VE with advanced features including RAM-based installation, ZFS on LUKS encryption, health checks, and extensive validation capabilities.

The installer has been refactored to use a consistent plain-text command-line interface (CLI) for all user interactions, removing dependencies on graphical or semi-graphical utilities like `dialog` to enhance robustness in minimal or debug environments.

## Features

### Core Installation Features

* **ZFS Root on LUKS:** Installs Proxmox VE with a ZFS root filesystem on top of LUKS encrypted disks for enhanced security and reliability.
  * **Flexible Disk Support:** Handles multiple disk configurations including mirrored pools, single disk setups, and RAIDz variants.
  * **Optimized ZFS Performance:** Configures ZFS parameters for optimal performance based on your hardware profile.
  * **Automatic Pool Creation:** Creates and configures ZFS pools with best-practice settings and mountpoints.

* **YubiKey Integration:** Secure your LUKS encryption with a YubiKey for two-factor authentication.
  * **Hardware-Based Security:** The YubiKey acts as an additional factor for unlocking encrypted drives at boot.
  * **Interactive Enrollment:** Guided YubiKey setup and enrollment during installation.
  * **Fallback Options:** Configures passphrase fallback for recovery scenarios.

* **Bootloader Options:**
  * **GRUB (Default):** Standard EFI bootloader installed on the target system's EFI partition with LUKS/ZFS support.
  * **Clover (Optional):** Install the Clover bootloader to a separate drive (e.g., USB stick) for systems where primary storage isn't directly bootable.

### Installation Environment

* **RAM-Based Installation:** Pivots to a RAM environment for stable installation regardless of source media.
  * **Source Independence:** Once started, installation continues even if the installation media is removed.
  * **Resource Optimization:** Automatically determines and allocates appropriate RAM resources.

* **Network Configuration:**
  * **Early & Final Setup:** Configures networking both during installation and for the target system.
  * **Interface Management:** Handles complex network configurations including bonds, bridges, and VLANs.
  * **Proxmox-Ready:** Sets up network for immediate Proxmox functionality after installation.

* **Package Management:**
  * **Intelligent Downloads:** Downloads required packages with dependency resolution.
  * **Offline Support:** Can use pre-downloaded packages for offline installation.
  * **Repository Configuration:** Sets up appropriate package sources for Proxmox.

### Validation & Health Check Features

* **Validation Mode:**
  * **Pre-Flight Checks:** Validate system requirements and configuration without making changes.
  * **Detailed Reporting:** Generates comprehensive validation reports on system readiness.
  * **Interactive & Non-Interactive:** Supports both plain-text interactive prompts and automated validation.

* **Health Checks:**
  * **Incremental Verification:** Performs health checks after each major installation step.
  * **System Integrity:** Validates critical system components and configurations.
  * **Abort on Critical:** Prevents cascading failures by aborting on critical issues.

* **SMART Disk Diagnostics:**
  * **Multi-Protocol Support:** Handles both SATA/SAS and NVMe drives.
  * **Attribute Analysis:** Checks SMART attributes against known-good thresholds.
  * **Self-Test Integration:** Offers interactive disk self-tests with user confirmation.
  * **Health Logging:** Detailed logging of disk health status for future reference.

* **Comprehensive Final Check:**
  * **End-to-End Verification:** Performs final system-wide health assessment.
  * **Component Testing:** Validates disks, LUKS, ZFS, system files, and network.
  * **Detailed Results:** Provides actionable information on any detected issues.

### Usability & Control

* **Configuration Options:**
  * **Command-Line Arguments:** Extensive CLI options for controlling installation behavior.
  * **Configuration Files:** Support for pre-defined configuration files for unattended installation.
  * **Interactive CLI Prompts:** User-friendly plain-text prompts for guided installation, ensuring compatibility in minimal environments.

* **Robust Error Handling:**
  * **Comprehensive Logging:** Detailed logs of all installation steps and decisions.
  * **Trap Handlers:** Graceful handling of errors and unexpected conditions.
  * **Clear Messaging:** User-friendly error messages with troubleshooting guidance.

* **Modular Design:**
  * **Component Separation:** Clean separation of concerns for maintainability.
  * **Extension Points:** Easy addition of new features through modular architecture.
  * **Script Independence:** Individual modules can be used standalone for specific tasks.
    *   **Local .deb Package Cache:** If required Debian packages are not available in the installation environment (e.g., air-gapped setup), the script can download them if an internet connection is present initially. These are stored in a `debs` subdirectory. This includes all necessary packages for features like ZFS, LUKS, and YubiKey support.
    *   The installer can then use these cached .deb packages to install Proxmox VE and its dependencies without internet access.
*   **Configuration Management:**
    *   **Text-based User Interface (TUI):** Guided dialogs for all installation options.
    *   **Save/Load Configuration:** Option to save all selected installation settings to a configuration file. This file can be used for non-interactive, automated deployments.
*   **Security & Robustness:**
    *   Detailed logging of the installation process.
    *   LUKS header backup utility to a separate removable device.
    *   Clear warnings for destructive operations.
    *   Error handling for critical steps.

## Requirements

*   System booted in EFI mode.
*   x86_64 architecture.
*   Minimum 4GB RAM (more recommended, especially if using RAM disk pivot).
*   Target disks for Proxmox VE installation.
*   Optional: A separate small USB drive for detached LUKS headers if that mode is chosen.
*   Optional: A separate small USB drive for Clover bootloader if that option is chosen.
*   Optional: A YubiKey for LUKS YubiKey protection.
*   Proxmox VE compatible hardware.
*   Internet connection (for initial .deb package download if not already cached, and for Proxmox/Debian repositories during installation unless all packages are cached).

## Usage

```bash
# Run the installer interactively
sudo ./installer.sh

# Run with a specific configuration file
sudo ./installer.sh --config my_config.conf

# Run in validation mode only (no changes made)
sudo ./installer.sh --validate

# Run without RAM boot pivoting
sudo ./installer.sh --no-ram-boot

# Show help
./installer.sh --help
```

### Basic Installation

1. Boot your target machine with a live Linux environment that includes the necessary tools (bash, coreutils, parted, cryptsetup, zfsutils-linux, debootstrap, etc.) or use the provided Proxmox debug environment.
2. Ensure the script and its associated files are accessible.
3. Run the main installer script: `./installer.sh`
4. Follow the on-screen prompts to configure your installation.

**Disclaimer:** This script performs destructive operations on disks. Ensure you have backed up any important data from the target disks before proceeding. Use at your own risk.

## Validation Mode

Validation mode allows you to verify system compatibility and configuration without making any changes to your system. This is useful for:

* Pre-flight checks before actual installation
* Verifying hardware compatibility
* Checking disk configurations
* Testing network settings
* Validating ZFS and LUKS configurations

To use validation mode:

```bash
sudo ./installer.sh --validate
```

This will generate a detailed validation report showing all checks performed and their results. In interactive mode, a dialog will present the results and allow you to view details.

## Health Checks

The installer performs comprehensive health checks at key points during the installation process:

* After LUKS setup - Validates encryption configuration
* After ZFS setup - Checks pool status and health
* After system file installation - Verifies critical system files
* After bootloader installation - Ensures boot configuration is correct
* After network configuration - Tests connectivity
* Final comprehensive check - End-to-end system verification

Each health check includes SMART disk diagnostics where appropriate, ensuring disk reliability throughout the installation process.

## Module Structure

The installer is built with a modular architecture:

* `installer.sh` - Main script and entry point
* `validation_module.sh` - System compatibility and configuration validation
* `health_checks.sh` - Post-installation verification and health checks
* `smart_tools.sh` - SMART disk diagnostic tools
* `zfs_logic.sh` - ZFS pool creation and configuration
* `encryption_logic.sh` - LUKS encryption setup
* `network_config.sh` - Network configuration
* `ramdisk_setup.sh` - RAM environment preparation
* `bootloader_logic.sh` - Bootloader installation and configuration
* `package_management.sh` - Package download utility for offline installation

## Configuration File Format

A sample configuration file contains settings for all installer options. You can use this as a template for unattended installations:

```bash
# Target disks for installation (comma-separated)
TARGET_DISKS=/dev/sda,/dev/sdb

# ZFS pool configuration
ZFS_POOL_NAME=rpool
ZFS_RAID_TYPE=mirror       # single, mirror, raidz1, raidz2
ZFS_ASHIFT=12             # 9=512B, 12=4KB, 13=8KB sectors

# LUKS configuration
USE_LUKS=true
DETACHED_HEADER=false     # Whether to use detached headers
LUKS_HEADER_DRIVE=/dev/sdc # Only used if DETACHED_HEADER=true

# YubiKey configuration
USE_YUBIKEY=false         # Enable YubiKey integration

# Network configuration
NETWORK_MODE=dhcp        # dhcp or static
IP_ADDRESS=192.168.1.100  # Only used if NETWORK_MODE=static
GATEWAY=192.168.1.1       # Only used if NETWORK_MODE=static
DNS_SERVERS=8.8.8.8,1.1.1.1

# Bootloader configuration
USE_CLOVER=false          # Use Clover bootloader
CLOVER_DRIVE=/dev/sdd     # Drive for Clover bootloader
```
