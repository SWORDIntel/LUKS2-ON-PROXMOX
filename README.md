# Proxmox VE Advanced Installer with ZFS on LUKS

This script provides a comprehensive, TUI-driven utility for installing Proxmox VE with a secure and flexible ZFS on LUKS2 setup. It is designed to handle various scenarios, including installations on non-bootable NVMe drives by leveraging a separate bootloader drive.

## Features

*   **ZFS on Root:** Full support for ZFS as the root filesystem, offering advanced data management capabilities.
    *   Configurable RAID levels: single disk, mirror (RAID-1), RAID-Z1, RAID-Z2.
    *   Adjustable ZFS properties: `ashift`, `recordsize`, `compression` (lz4, gzip, zstd, off).
*   **Full Disk Encryption (LUKS2):** Robust encryption for all data partitions.
    *   **Standard LUKS:** Headers stored on the same disk as encrypted data.
    *   **Detached LUKS Headers:** Option to store LUKS headers on a separate, removable drive (e.g., USB stick) for enhanced physical security. The system will not boot without this header drive.
    *   **YubiKey Integration:** Secure your LUKS encryption with a YubiKey. The YubiKey acts as an additional factor for unlocking the encrypted drives at boot, alongside the primary passphrase. Enrollment occurs during installation.
*   **Bootloader Options:**
    *   **GRUB (Default):** Standard EFI bootloader installed on the target system's EFI partition.
    *   **Clover (Optional):** Install the Clover bootloader to a separate drive (e.g., USB stick). This is particularly useful for systems where the primary storage (like NVMe drives) is not bootable by the system firmware, or for legacy hardware compatibility.
*   **Installation Environment:**
    *   **RAM Disk Pivot:** The installer can copy itself to a RAM disk, allowing installation onto the device it was booted from (e.g., installing from a USB stick onto the same USB stick, though typically used to free up the original boot media for other purposes).
    *   **Pre-flight Checks:** Performs various system checks before starting the installation (root access, EFI mode, RAM, disk space, essential commands).
*   **Networking:**
    *   DHCP or Static IP configuration for the Proxmox VE host.
    *   Automatic creation of a Linux bridge (`vmbr0`) connected to the primary network interface.
*   **Offline Installation:**
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

1.  Boot your target machine with a live Linux environment that includes the necessary tools (bash, coreutils, parted, cryptsetup, zfsutils-linux, debootstrap, etc.) or use the provided Proxmox debug environment.
2.  Ensure the script and its associated files (e.g., `core_logic.sh`, `debs/` directory) are accessible.
3.  Run the main installer script: `./installer.sh`
4.  Follow the on-screen prompts to configure your installation.

**Disclaimer:** This script performs destructive operations on disks. Ensure you have backed up any important data from the target disks before proceeding. Use at your own risk.
