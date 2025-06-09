# Proxmox VE Advanced Installer with ZFS Native Encryption - STILLLLLLLL BROKEN AS OF THIS TIME

A customizable, robust, and comprehensive installer script for setting up Proxmox VE with advanced features including RAM-based installation, ZFS native encryption for the root filesystem, health checks, and extensive validation capabilities.

## Features

### Core Installation Features

* **ZFS Native Encryption for Root Filesystem:** Installs Proxmox VE with a ZFS root filesystem utilizing ZFS native encryption for enhanced security and reliability.
  * Supports passphrase-based encryption for the ZFS pool.
  * Optionally supports keyfile-based encryption, where the keyfile can be protected by a YubiKey (potentially on a small, separate LUKS-encrypted partition).
  * **Flexible Disk Support:** Handles multiple disk configurations including mirrored pools, single disk setups, and RAIDz variants.
  * **Optimized ZFS Performance:** Configures ZFS parameters for optimal performance based on your hardware profile.
  * **Automatic Pool Creation:** Creates and configures ZFS pools with best-practice settings, encryption, and mountpoints.

* **YubiKey Integration:** Enhance security by using a YubiKey.
  * **Keyfile Protection:** The YubiKey can be used to unlock a LUKS-encrypted partition that stores the keyfile for ZFS native encryption. This adds a hardware-backed layer to your ZFS encryption.
  * **Interactive Enrollment:** Guided YubiKey setup and enrollment during installation for the LUKS-protected keyfile.
  * **Fallback Options:** Configures passphrase fallback for recovery scenarios (for the LUKS-protected keyfile or direct ZFS passphrase).

* **Bootloader Options:**
  * **GRUB (Default):** Standard EFI bootloader installed on the target system's EFI partition with ZFS support.
  * **Clover (Optional):** Install the Clover bootloader to a separate drive (e.g., USB stick) for systems where primary storage isn't directly bootable.
  * **ZFSBootMenu (Optional):** Install ZFSBootMenu to a separate drive (e.g., USB stick). ZFSBootMenu provides a command-line environment that can scan for ZFS pools, identify bootable ZFS datasets, and boot Linux kernels directly from those datasets. It's particularly useful for flexible ZFS boot environment management. More details at [https://docs.zfsbootmenu.org/en/v3.0.x/](https://docs.zfsbootmenu.org/en/v3.0.x/).

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
  * **Interactive & Non-Interactive:** Supports both dialog-based and automated validation.

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
  * **Component Testing:** Validates disks, ZFS, system files, network, and LUKS (if used for keyfile encryption).
  * **Detailed Results:** Provides actionable information on any detected issues.

### Usability & Control

The installer offers flexible control methods, supporting both interactive guided setup via a Text-based User Interface (TUI) and non-interactive automated deployments through command-line arguments and configuration files.

* **Configuration Options:**
  * **Command-Line Arguments:** Extensive CLI options for controlling installation behavior, suitable for scripting and automation.
  * **Configuration Files:** Support for pre-defined configuration files for fully unattended installation.
  * **Interactive Dialogs (TUI):** When run without automation flags, provides user-friendly dialogs (using utilities like `dialog`) for guided setup.

* **Robust Error Handling:**
  * **Comprehensive Logging:** Detailed logs of all installation steps and decisions.
  * **Trap Handlers:** Graceful handling of errors and unexpected conditions.
  * **Clear Messaging:** User-friendly error messages with troubleshooting guidance.

* **Modular Design:**
  * **Component Separation:** Clean separation of concerns for maintainability.
  * **Extension Points:** Easy addition of new features through modular architecture.
  * **Script Independence:** Individual modules can be used standalone for specific tasks.
    *   **Local .deb Package Cache:** If required Debian packages are not available in the installation environment (e.g., air-gapped setup), the script can download them if an internet connection is present initially. These are stored in a `debs` subdirectory. This includes all necessary packages for features like ZFS, (optionally LUKS for keyfile encryption), and YubiKey support.
    *   The installer can then use these cached .deb packages to install Proxmox VE and its dependencies without internet access.
*   **Configuration Management (Interaction Modes):**
    *   **Interactive Mode (TUI):** Utilizes text-based dialogs (e.g., via the `dialog` utility) to guide users through all installation choices. This is the default mode when no automation flags are provided.
    *   **Non-Interactive Mode:** Achieved using command-line arguments or by providing a comprehensive configuration file.
    *   **Save/Load Configuration:** Facilitates transitioning from an interactive setup to an automated one by allowing users to save settings from the TUI into a configuration file.
*   **Security & Robustness:**
    *   Detailed logging of the installation process.
    *   Utility for backing up critical encryption information (e.g., LUKS header for keyfile partition, ZFS encryption keys if managed externally).
    *   Clear warnings for destructive operations.
    *   Error handling for critical steps.

## Requirements

*   System booted in EFI mode.
*   x86_64 architecture.
*   Minimum 4GB RAM (more recommended, especially if using RAM disk pivot).
*   Target disks for Proxmox VE installation.
*   Optional: A separate small USB drive if using it to store a LUKS-encrypted keyfile for ZFS native encryption.
*   Optional: A separate small USB drive for Clover bootloader if that option is chosen.
*   Optional: A separate small USB drive for ZFSBootMenu if that option is chosen.
*   Optional: A YubiKey, if used to protect the LUKS-encrypted keyfile for ZFS native encryption.
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
* Validating ZFS (and optionally LUKS for keyfile) configurations

To use validation mode:

```bash
sudo ./installer.sh --validate
```

This will generate a detailed validation report showing all checks performed and their results. In interactive mode, a dialog will present the results and allow you to view details.

## Health Checks

The installer performs comprehensive health checks at key points during the installation process:

* After encryption setup (ZFS native, or LUKS for keyfile) - Validates encryption configuration
* After ZFS setup - Checks pool status and health (including encryption status)
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
* `zfs_setup.sh` - ZFS pool creation and configuration (including native encryption)
* `luks_setup.sh` - LUKS encryption setup (primarily for ZFS keyfiles if used)
* `network_setup.sh` - Network configuration
* `ramdisk_setup.sh` - RAM environment preparation
* `bootloader_setup.sh` - Bootloader installation and configuration
* `download_debs.sh` - Package download utility for offline installation

## Configuration File Format

A sample configuration file contains settings for all installer options. You can use this as a template for unattended installations:

```bash
# Target disks for installation (comma-separated)
TARGET_DISKS=/dev/sda,/dev/sdb

# ZFS pool configuration
ZFS_POOL_NAME=rpool
ZFS_RAID_TYPE=mirror       # single, mirror, raidz1, raidz2
ZFS_ASHIFT=12             # 9=512B, 12=4KB, 13=8KB sectors

# ZFS Native Encryption configuration
ZFS_NATIVE_ENCRYPTION=yes  # Enable ZFS native encryption for the root pool
# ZFS_ENCRYPTION_PASSPHRASE_ONCE=yes # Ask for passphrase only once during setup, then use a keyfile
ZFS_ENCRYPTION_ALGORITHM=aes-256-gcm # Encryption algorithm
# KEYFILE_LUKS_ENCRYPTED=yes # Set to yes if the ZFS keyfile is on a LUKS encrypted partition
# KEYFILE_LUKS_DRIVE=/dev/sdx # Device for the LUKS encrypted keyfile
# USE_YUBIKEY_FOR_ZFS_KEY=yes # Use YubiKey to unlock the LUKS partition containing the ZFS keyfile

# LUKS configuration (Legacy - primarily for ZFS keyfile encryption if used, not for root FS)
# USE_LUKS=true             # Set to true if using LUKS for ZFS keyfile encryption
# DETACHED_HEADER=false     # Whether to use detached headers for the keyfile's LUKS partition
# LUKS_HEADER_DRIVE=/dev/sdc # Only used if DETACHED_HEADER=true for the keyfile's LUKS partition

# YubiKey configuration
USE_YUBIKEY=false         # Enable YubiKey integration (e.g., for unlocking the LUKS-encrypted ZFS keyfile)

# Network configuration
NETWORK_MODE=dhcp        # dhcp or static
IP_ADDRESS=192.168.1.100  # Only used if NETWORK_MODE=static
GATEWAY=192.168.1.1       # Only used if NETWORK_MODE=static
DNS_SERVERS=8.8.8.8,1.1.1.1

# Bootloader configuration
USE_CLOVER=false          # Use Clover bootloader
CLOVER_DRIVE=/dev/sdd     # Drive for Clover bootloader
USE_ZFSBOOTMENU=false     # Use ZFSBootMenu bootloader
ZFSBOOTMENU_DRIVE=/dev/sde # Drive for ZFSBootMenu (only if USE_ZFSBOOTMENU=true)
```
