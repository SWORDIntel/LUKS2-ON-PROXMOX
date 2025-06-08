```mermaid
flowchart TD
    %% Main entry points
    START[Start installer.sh] --> MAIN[main function]
    MAIN --> PARSE_ARGS[Parse arguments]
    
    %% Command line argument handling
    PARSE_ARGS -->|--help| SHOW_HELP[Display help and exit]
    PARSE_ARGS -->|--version| SHOW_VERSION[Display version and exit]
    PARSE_ARGS -->|--validate| SET_VALIDATE_MODE[Set validation mode]
    PARSE_ARGS -->|--config| READ_CONFIG[Read specified config file]
    PARSE_ARGS -->|--no-ram-boot| DISABLE_RAM_BOOT[Disable RAM boot]
    
    %% Environment setup
    PARSE_ARGS --> CHECK_ROOT[Check if running as root]
    CHECK_ROOT -->|Not root| EXIT_NOT_ROOT[Exit: must be root]
    CHECK_ROOT -->|Is root| SOURCE_MODULES[Source module scripts]
    
    %% Loading external modules
    SOURCE_MODULES --> SOURCE_VALIDATION[Source validation_module.sh]
    SOURCE_MODULES --> SOURCE_HEALTH[Source health_checks.sh] 
    SOURCE_MODULES --> SOURCE_SMART[Source smart_tools.sh]
    SOURCE_MODULES --> SOURCE_ZFS[Source zfs_setup.sh]
    SOURCE_MODULES --> SOURCE_LUKS[Source luks_setup.sh]
    SOURCE_MODULES --> SOURCE_NETWORK[Source network_setup.sh]
    SOURCE_MODULES --> SOURCE_RAMDISK[Source ramdisk_setup.sh]
    SOURCE_MODULES --> SOURCE_BOOTLOADER[Source bootloader_setup.sh]
    
    %% Configuration setup
    SOURCE_MODULES --> LOAD_CONFIG[Load configuration]
    LOAD_CONFIG -->|Validation mode| VALIDATE_INSTALL[validate_installation]
    VALIDATE_INSTALL --> GENERATE_REPORT[Generate validation report]
    GENERATE_REPORT -->|Validation fails| EXIT_VALIDATION_FAIL[Exit: validation failed]
    GENERATE_REPORT -->|Interactive mode| SHOW_DIALOG[Display validation dialog]
    GENERATE_REPORT -->|Validation passed| EXIT_VALIDATION_PASS[Exit: validation passed]

    %% Main installation path
    LOAD_CONFIG -->|Normal mode| CHECK_RAM_ENV[Check if in RAM environment]
    
    %% RAM environment setup
    CHECK_RAM_ENV -->|Not in RAM| INTERNET_CHECK[Check internet connectivity]
    INTERNET_CHECK -->|No internet| CONFIGURE_NETWORK_EARLY[configure_network_early]
    INTERNET_CHECK -->|Has internet| SKIP_NETWORK_SETUP[Skip network setup]
    CONFIGURE_NETWORK_EARLY --> PREPARE_RAM_ENV[prepare_ram_environment]
    SKIP_NETWORK_SETUP --> PREPARE_RAM_ENV
    PREPARE_RAM_ENV --> RELAUNCH[Re-launch script in RAM]
    
    %% Installation logic (in RAM)
    CHECK_RAM_ENV -->|In RAM| RUN_INSTALLATION[run_installation_logic]

    %% Installation process
    RUN_INSTALLATION --> BACKUP_FILES[Backup critical files]
    BACKUP_FILES --> CHECK_INTERNET[Check internet connectivity]
    CHECK_INTERNET -->|No internet| CONFIGURE_NETWORK[configure_network]
    CHECK_INTERNET -->|Has internet| DOWNLOAD_PACKAGES[Download required packages]
    CONFIGURE_NETWORK --> DOWNLOAD_PACKAGES

    %% Disk setup
    DOWNLOAD_PACKAGES --> DISK_SETUP_START[Prepare disks]
    DISK_SETUP_START --> SETUP_BOOT_DISK[Setup boot disk]
    SETUP_BOOT_DISK -->|LUKS enabled| SETUP_LUKS[setup_luks]
    SETUP_LUKS -->|Health check| LUKS_HEALTH[health_check LUKS]
    SETUP_LUKS -->|ZFS on LUKS| SETUP_ZFS_ON_LUKS[setup_zfs_on_luks]
    SETUP_BOOT_DISK -->|No LUKS| SETUP_ZFS_DIRECT[setup_zfs_direct]
    
    %% ZFS setup and health check
    SETUP_ZFS_ON_LUKS --> ZFS_HEALTH[health_check ZFS]
    SETUP_ZFS_DIRECT --> ZFS_HEALTH
    
    %% Base system installation
    ZFS_HEALTH --> INSTALL_BASE_SYSTEM[Install base system]
    INSTALL_BASE_SYSTEM --> SYSTEM_FILES_HEALTH[health_check system files]
    
    %% System configuration
    SYSTEM_FILES_HEALTH --> CONFIGURE_SYSTEM[Configure system]
    CONFIGURE_SYSTEM --> INSTALL_BOOTLOADER[Install bootloader]
    INSTALL_BOOTLOADER -->|Health check| BOOTLOADER_HEALTH[health_check bootloader]
    
    %% Optional Clover bootloader
    INSTALL_BOOTLOADER -->|Clover enabled| INSTALL_CLOVER[Install Clover bootloader]
    INSTALL_CLOVER --> CLOVER_HEALTH[health_check Clover]
    INSTALL_CLOVER --> FINAL_SETUP[Final setup steps]
    BOOTLOADER_HEALTH --> FINAL_SETUP
    
    %% Network configuration
    FINAL_SETUP --> CONFIGURE_NETWORK_FINAL[Configure network]
    CONFIGURE_NETWORK_FINAL --> NETWORK_HEALTH[health_check network]
    
    %% Final health check
    NETWORK_HEALTH --> FINAL_HEALTH_CHECK[comprehensive_health_check]
    FINAL_HEALTH_CHECK -->|All checks pass| INSTALLATION_SUCCESS[Installation successful]
    FINAL_HEALTH_CHECK -->|Any check fails| INSTALLATION_WARNING[Installation with warnings]
    
    %% Smart Tools Integration
    LUKS_HEALTH --> SMART_CHECK_DISKS[check_disk_smart]
    ZFS_HEALTH --> SMART_CHECK_ZFS[check_zfs_disk_health]
    SYSTEM_FILES_HEALTH --> SMART_PERIODIC[schedule_smart_periodic_checks]
    
    %% SMART components
    subgraph SMART_TOOLS [smart_tools.sh]
        SMART_SATA[check_sata_smart]
        SMART_NVME[check_nvme_smart]
        SMART_PROMPT[prompt_for_test]
        SMART_LOG[log_smart_results]
    end
    
    SMART_CHECK_DISKS --> SMART_TOOLS
    
    %% Health Check components
    subgraph HEALTH_CHECKS [health_checks.sh]
        CHECK_DISKS[check_disks]
        CHECK_LUKS[check_luks]
        CHECK_ZFS[check_zfs_pool]
        CHECK_SYSTEM[check_system_files]
        CHECK_NETWORK[check_network]
        CHECK_COMPREHENSIVE[comprehensive_check]
    end
    
    LUKS_HEALTH --> HEALTH_CHECKS
    ZFS_HEALTH --> HEALTH_CHECKS
    SYSTEM_FILES_HEALTH --> HEALTH_CHECKS
    NETWORK_HEALTH --> HEALTH_CHECKS
    FINAL_HEALTH_CHECK --> HEALTH_CHECKS
    
    %% Validation components
    subgraph VALIDATION_MODULE [validation_module.sh]
        VALIDATE_SYSTEM[validate_system_requirements]
        VALIDATE_DISK[validate_disk_config]
        VALIDATE_NETWORK[validate_network_config]
        VALIDATE_ZFS[validate_zfs_config]
        VALIDATE_LUKS[validate_luks_config]
        VALIDATE_BOOT[validate_bootloader_config]
        VALIDATE_REPORT[generate_validation_report]
    end
    
    VALIDATE_INSTALL --> VALIDATION_MODULE
```

## Script Dependencies and Call Order

1. **installer.sh** (Main Script)
   - Sources and calls all other modules
   - Controls overall installation flow
   - Handles command-line arguments and configuration

2. **validation_module.sh**
   - Called early in the process when `--validate` flag is used
   - Validates system requirements and configuration without making changes
   - Provides a validation report

3. **health_checks.sh**
   - Called after each major installation step
   - Verifies the success of critical installation components
   - Can abort installation on critical failures
   - Performs a final comprehensive health check

4. **smart_tools.sh**
   - Called by health_checks.sh to verify disk health
   - Implements SMART diagnostics for different disk types (SATA/SAS/NVMe)
   - Logs detailed drive information

5. **zfs_setup.sh**
   - Handles ZFS pool creation and configuration
   - Can be used on raw disks or on top of LUKS

6. **luks_setup.sh**
   - Sets up LUKS encryption on target disks
   - Configures encryption parameters and key management

7. **network_setup.sh**
   - Configures network interfaces early in the process if needed
   - Sets up final network configuration for the installed system

8. **ramdisk_setup.sh**
   - Prepares and pivots to RAM environment
   - Ensures stable installation environment

9. **bootloader_setup.sh**
   - Installs and configures the bootloader (GRUB or Clover)
   - Sets up boot parameters for ZFS and LUKS

## Execution Flow States

1. **Validation Mode**
   - Performs all validation checks without making any changes
   - Generates a validation report and exits

2. **Normal Installation Mode**
   - First phase: Environment preparation and RAM pivot
   - Second phase: Actual installation (runs in RAM environment)

3. **Health Check Points**
   - After LUKS setup
   - After ZFS setup
   - After system file installation
   - After bootloader installation
   - After network configuration
   - Final comprehensive check

## Error Handling

- Strict error handling throughout with trap handlers
- Detailed logging of all steps
- Installation aborts on critical failures
- Validation can detect issues before installation begins

## User Interaction Points

- Initial argument parsing and configuration
- Validation results in interactive mode
- SMART self-test prompts
- Final installation report
