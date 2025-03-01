#!/bin/bash

#=====================================================================
# Arch Linux Automated Installation Script for ASUS ZenBook Q528EH
#=====================================================================

# Exit on error
set -e

# Function to log messages
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to handle errors
handle_error() {
  log "ERROR: $1"
  exit 1
}

# Function to check command success
check_success() {
  if [ $? -ne 0 ]; then
    handle_error "$1"
  fi
}

echo "===================================================================="
echo "     Arch Linux Automated Installation for ASUS ZenBook Q528EH      "
echo "===================================================================="
echo ""
echo "WARNING: This script will erase data on the selected disk."
echo "Make sure you have backed up your important data before proceeding."
echo ""
echo "This script will automate the installation of Arch Linux on your"
echo "ASUS ZenBook Q528EH with the following configuration:"
echo "  - UEFI boot with GRUB (with BIOS fallback option)"
echo "  - Partitioning: EFI (512MB), Swap (auto-sized), LVM (remainder)"
echo "  - LVM Configuration: Root (120GB), Home (remainder)"
echo "  - KDE Plasma desktop environment"
echo "  - NVIDIA + Intel hybrid graphics with optimus-manager"
echo "  - Touchscreen and stylus support"
echo "  - Resource sharing capabilities (NFS, Samba, BOINC, SLURM)"
echo "  - Basic security configuration with UFW and SSH"
echo ""
echo "Press ENTER to continue or CTRL+C to abort..."
read

# Ensure you have root privileges
if [ "$EUID" -ne 0 ]; then
  handle_error "Please run as root"
fi

# Function to setup network
setup_network() {
  log "Setting up network connection..."
  echo "1. Ethernet (dhcpcd)"
  echo "2. WiFi (iwd)"
  read -p "Select (1-2): " net_choice
  
  if [ "$net_choice" = "1" ]; then
    log "Setting up Ethernet with dhcpcd..."
    pacman -Sy --noconfirm dhcpcd || handle_error "Failed to install dhcpcd"
    systemctl start dhcpcd || handle_error "Failed to start dhcpcd"
  elif [ "$net_choice" = "2" ]; then
    log "Setting up WiFi with iwd..."
    pacman -Sy --noconfirm iwd || handle_error "Failed to install iwd"
    systemctl start iwd || handle_error "Failed to start iwd"
    iwctl || handle_error "Failed to run iwctl"
  else
    handle_error "Invalid selection"
  fi
  
  # Check network
  for i in {1..3}; do
    if ping -c 1 archlinux.org &> /dev/null; then
      log "Network connection established"
      return 0
    fi
    log "Waiting for network connection (attempt $i/3)..."
    sleep 5
  done
  
  handle_error "Network setup failed after 3 attempts"
}

# Check for active network connection
log "Checking network connection..."
if ! ping -c 1 archlinux.org &> /dev/null; then
  log "No network connection detected. Starting setup..."
  setup_network
fi

# Update system clock
timedatectl set-ntp true
check_success "Failed to set NTP"

# List available storage devices
echo "Available storage devices:"
lsblk

# Prompt for the storage device to use
read -p "Enter the device to install Arch Linux on (e.g., /dev/nvme0n1): " dev

# Ensure the user has provided a valid device
if [ ! -b "$dev" ]; then
  handle_error "Invalid device: $dev"
fi

# Check disk space
log "Checking disk space..."
disk_size=$(lsblk -b -n -o SIZE "$dev" | head -n1)
min_size=$((30*1024*1024*1024)) # 30GB minimum
if [ "$disk_size" -lt "$min_size" ]; then
  handle_error "Disk is too small. Minimum 30GB required, found $(($disk_size/1024/1024/1024))GB"
fi
log "Disk space check passed: $(($disk_size/1024/1024/1024))GB available"

# Warning before proceeding
echo "WARNING: This will erase all data on $dev"
read -p "Are you sure you want to continue? (y/n): " confirm
if [ "$confirm" != "y" ]; then
  log "Installation aborted by user"
  exit 0
fi

# NEW: Comprehensive pre-installation disk cleanup
log "Starting comprehensive disk cleanup..."
log "This will completely wipe all data, partitions, and metadata from $dev"
read -p "Continue with aggressive disk cleanup? (y/n): " cleanup_confirm
if [ "$cleanup_confirm" = "y" ]; then
  log "Performing aggressive disk cleanup..."
  
  # Kill all processes that might be using the disk
  log "Terminating processes that might be using the disk..."
  fuser -km "${dev}"* 2>/dev/null || true
  
  # Unmount any mounted partitions
  log "Unmounting all partitions..."
  umount -f "${dev}"* 2>/dev/null || true
  
  # Deactivate any LVM on the disk
  log "Deactivating LVM volumes..."
  if command -v vgchange &> /dev/null; then
    # Find any volume groups on this device
    potential_vgs=$(pvs --noheadings -o vg_name "${dev}"* 2>/dev/null | tr -d ' ' || true)
    if [ -n "$potential_vgs" ]; then
      for vg in $potential_vgs; do
        log "Deactivating volume group: $vg"
        vgchange -an "$vg" || true
      done
    fi
    
    # Remove any LVM metadata from all partitions
    log "Removing LVM metadata from partitions..."
    for part in $(lsblk -nlo NAME "$dev" | grep -v "$(basename "$dev")$"); do
      log "Checking for LVM on /dev/$part"
      pvremove -ff -y "/dev/$part" 2>/dev/null || true
    done
  fi
  
  # Close any LUKS containers
  log "Closing any LUKS containers..."
  if command -v cryptsetup &> /dev/null; then
    for part in $(lsblk -nlo NAME "$dev" | grep -v "$(basename "$dev")$"); do
      cryptsetup close "/dev/$part" 2>/dev/null || true
    done
  fi
  
  # Wipe all signatures from the disk and partitions
  log "Wiping all signatures from disk and partitions..."
  log "Wiping main disk: $dev"
  wipefs -a "$dev" || log "Warning: Failed to wipe signatures from $dev"
  
  # Wipe all existing partitions
  for part in $(ls ${dev}* 2>/dev/null | grep -v "^$dev$"); do
    log "Wiping partition: $part"
    wipefs -a "$part" 2>/dev/null || true
  done
  
  # Zero out the first and last few MB of the disk
  log "Zero-ing out the beginning and end of disk..."
  dd if=/dev/zero of="$dev" bs=1M count=10 conv=fsync || log "Warning: Failed to zero beginning of disk"
  
  # Calculate disk size in 512-byte sectors
  local_disk_size=$(blockdev --getsz "$dev")
  if [ $? -eq 0 ] && [ "$local_disk_size" -gt 20000 ]; then
    # Zero out the last 10MB
    seek_val=$((local_disk_size/2048 - 10))
    dd if=/dev/zero of="$dev" bs=1M count=10 seek=$seek_val conv=fsync || log "Warning: Failed to zero end of disk"
  fi
  
  # Create new empty partition table (will be recreated later in the script)
  log "Creating empty partition table..."
  parted -s "$dev" mklabel gpt || log "Warning: Failed to create empty partition table"
  
  # Use gdisk to perform a deeper clean if available
  if command -v gdisk &> /dev/null; then
    log "Using gdisk to perform deeper cleanup..."
    echo -e "x\nz\ny\ny" | gdisk "$dev" || log "Warning: gdisk cleanup failed"
  fi
  
  # Final sync to ensure all writes are completed
  log "Syncing disk..."
  sync
  sleep 3
  
  log "Aggressive disk cleanup completed."
  log "Waiting for system to recognize changes..."
  sleep 5
else
  log "Skipping aggressive cleanup. Installation may fail if disk has issues."
fi

# Prompt for username, hostname and passwords
read -p "Enter your username: " username

read -p "Enter your hostname: " hostname

# Separate passwords for root and user
while true; do
  read -s -p "Enter root password: " root_password
  echo
  read -s -p "Confirm root password: " root_password_confirm
  echo
  [ "$root_password" = "$root_password_confirm" ] && break
  echo "Passwords do not match. Please try again."
done

while true; do
  read -s -p "Enter user password: " user_password
  echo
  read -s -p "Confirm user password: " user_password_confirm
  echo
  [ "$user_password" = "$user_password_confirm" ] && break
  echo "Passwords do not match. Please try again."
done

# Encrypt the passwords
encrypted_root_password=$(openssl passwd -6 "$root_password")
encrypted_user_password=$(openssl passwd -6 "$user_password")

# Ask for boot type
echo "Select boot type:"
echo "1. UEFI (modern hardware)"
echo "2. BIOS (legacy hardware)"
read -p "Select (1-2): " boot_type

# Determine boot mode based on selection and validation
is_uefi=true
if [ "$boot_type" = "2" ]; then
  is_uefi=false
elif [ "$boot_type" = "1" ]; then
  # Validate UEFI is available
  if [ ! -d "/sys/firmware/efi/efivars" ]; then
    log "Warning: UEFI variables not detected. UEFI selected but system might be in BIOS mode."
    read -p "Continue with UEFI anyway? (y/n): " uefi_override
    if [ "$uefi_override" != "y" ]; then
      is_uefi=false
    fi
  fi
else
  handle_error "Invalid boot type selection"
fi

# Determine swap size (1.5x RAM or minimum 4GB)
log "Determining optimal swap size..."
ram_size=$(free -m | awk '/^Mem:/{print $2}')
swap_size=$(( ram_size * 3 / 2 ))
if [ "$swap_size" -lt 4096 ]; then
  swap_size=4096
fi
log "RAM detected: ${ram_size}MB, Swap size set to: ${swap_size}MB"

# Calculate swap size in GiB with one decimal place
swap_size_gb=$(echo "scale=1; $swap_size/1024" | bc)
log "Swap size: ${swap_size_gb}GiB"

# Resource sharing options
echo "Enable resource sharing capabilities?"
echo "1. Yes - install NFS, Samba, BOINC, SLURM"
echo "2. No - skip resource sharing tools"
read -p "Select (1-2): " share_option

install_sharing=false
if [ "$share_option" = "1" ]; then
  install_sharing=true
fi

# Partition the disk
log "Partitioning the disk..."

# First make sure the disk is not mounted
log "Ensuring disk is not mounted..."
umount -f "${dev}"* 2>/dev/null || true

parted -s "$dev" mklabel gpt
check_success "Failed to create partition table"

if $is_uefi; then
  log "Creating UEFI partitions..."
  parted -s "$dev" mkpart "EFI" fat32 1MiB 513MiB
  check_success "Failed to create EFI partition"
  parted -s "$dev" set 1 esp on
  check_success "Failed to set ESP flag"
  parted -s "$dev" mkpart "swap" linux-swap 513MiB "$((513 + $swap_size))MiB"
  check_success "Failed to create swap partition"
  parted -s "$dev" mkpart "lvm" ext4 "$((513 + $swap_size))MiB" 100%
  check_success "Failed to create LVM partition"
  
  # Determine partition suffixes based on device type
  if [[ "$dev" == *"nvme"* ]]; then
    efi_part="${dev}p1"
    swap_part="${dev}p2"
    lvm_part="${dev}p3"
  else
    efi_part="${dev}1"
    swap_part="${dev}2"
    lvm_part="${dev}3"
  fi
else
  log "Creating BIOS partitions..."
  parted -s "$dev" mkpart "bios" ext4 1MiB 3MiB
  check_success "Failed to create BIOS boot partition"
  parted -s "$dev" set 1 bios_grub on
  check_success "Failed to set bios_grub flag"
  parted -s "$dev" mkpart "swap" linux-swap 3MiB "$((3 + $swap_size))MiB"
  check_success "Failed to create swap partition"
  parted -s "$dev" mkpart "lvm" ext4 "$((3 + $swap_size))MiB" 100%
  check_success "Failed to create LVM partition"
  
  # Determine partition suffixes
  if [[ "$dev" == *"nvme"* ]]; then
    bios_part="${dev}p1"
    swap_part="${dev}p2"
    lvm_part="${dev}p3"
  else
    bios_part="${dev}1"
    swap_part="${dev}2"
    lvm_part="${dev}3"
  fi
fi

# Reload the partition table to ensure kernel recognizes new partitions
log "Reloading partition table..."
partprobe "$dev" || log "Warning: partprobe failed, trying alternate methods"

# Try alternate methods to make the kernel recognize the partition table
if ! partprobe "$dev"; then
  log "Trying udevadm to trigger partition table reload..."
  udevadm trigger --subsystem-match=block
  udevadm settle
  
  log "Trying sysfs to trigger partition table reload..."
  if [[ "$dev" == *"nvme"* ]]; then
    device_name=$(basename "$dev")
    echo 1 > /sys/block/${device_name}/device/rescan 2>/dev/null || true
  else
    device_name=$(basename "$dev")
    echo 1 > /sys/block/${device_name}/device/rescan 2>/dev/null || true
  fi
  
  # Additional methods to force kernel to reload the partition table
  log "Trying additional methods to force partition table reload..."
  
  # Force a kernel partition table re-read with hdparm
  if command -v hdparm &> /dev/null; then
    log "Using hdparm to force partition table re-read..."
    hdparm -z "$dev" || log "hdparm failed, continuing with other methods"
  fi
  
  # Try using blockdev to reread the partition table
  if command -v blockdev &> /dev/null; then
    log "Using blockdev to force partition table re-read..."
    blockdev --rereadpt "$dev" || log "blockdev --rereadpt failed, continuing with other methods"
  fi
  
  # Force reread using direct kernel interface
  log "Forcing partition table re-read through kernel interface..."
  echo "w" | fdisk "$dev" >/dev/null 2>&1 || true
  
  # Last resort - try to manually detach and reattach the device (dangerous, only for NVMe)
  if [[ "$dev" == *"nvme"* ]] && [ -f "/sys/block/${device_name}/device/delete" ]; then
    log "WARNING: Attempting to detach and rescan NVMe device as last resort..."
    read -p "This is a potentially dangerous operation. Continue? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
      echo 1 > /sys/block/${device_name}/device/delete
      sleep 2
      echo 1 > /sys/devices/pci*/*/rescan
      sleep 5
    fi
  fi
  
  log "Waiting for partitions to be recognized..."
  sleep 10
  
  # Check if partitions exist after all attempts
  if $is_uefi; then
    if [[ "$dev" == *"nvme"* ]]; then
      if [ ! -b "${dev}p1" ] || [ ! -b "${dev}p2" ] || [ ! -b "${dev}p3" ]; then
        log "ERROR: Partitions still not recognized after multiple attempts."
        log "Manual intervention required:"
        log "1. Run 'partprobe $dev'"
        log "2. Check 'lsblk' to verify partitions are visible"
        log "3. If necessary, reboot and restart the installation"
        read -p "Press Enter to continue anyway (may fail) or Ctrl+C to abort..."
      fi
    else
      if [ ! -b "${dev}1" ] || [ ! -b "${dev}2" ] || [ ! -b "${dev}3" ]; then
        log "ERROR: Partitions still not recognized after multiple attempts."
        log "Manual intervention required:"
        log "1. Run 'partprobe $dev'"
        log "2. Check 'lsblk' to verify partitions are visible" 
        log "3. If necessary, reboot and restart the installation"
        read -p "Press Enter to continue anyway (may fail) or Ctrl+C to abort..."
      fi
    fi
  fi
fi

# Format partitions
log "Formatting partitions..."

# Check if partitions exist before formatting
if $is_uefi; then
  if [ -b "$efi_part" ]; then
    mkfs.fat -F32 "$efi_part"
    check_success "Failed to format EFI partition"
  else
    handle_error "EFI partition $efi_part does not exist or was not recognized by kernel"
  fi
fi

# Format swap if it exists
if [ -b "$swap_part" ]; then
  mkswap "$swap_part"
  check_success "Failed to create swap"
else
  handle_error "Swap partition $swap_part does not exist or was not recognized by kernel"
fi

# Check if LVM partition exists
if [ ! -b "$lvm_part" ]; then
  handle_error "LVM partition $lvm_part does not exist or was not recognized by kernel"
fi

# Set up LVM
log "Setting up LVM..."

# First attempt with standard methods
log "Attempting to create physical volume with pvcreate -ff..."
pvcreate -ff "$lvm_part"
if [ $? -ne 0 ]; then
  log "ERROR: Failed to create physical volume using pvcreate -ff"
  log "Attempting automatic recovery..."
  
  # Try cleaning the partition more thoroughly
  log "Cleaning partition more thoroughly..."
  dd if=/dev/zero of="$lvm_part" bs=1M count=10 || log "Warning: Failed to zero beginning of partition"
  wipefs -a "$lvm_part" || log "Warning: Failed to wipe signatures"
  
  # Try creating PV again
  log "Retrying pvcreate with force flag..."
  pvcreate -ff "$lvm_part"
  
  if [ $? -ne 0 ]; then
    log "Automatic recovery failed."
    log "-----------------------------------------------------"
    log "EMERGENCY RECOVERY OPTION:"
    log "This will completely recreate the partition from scratch."
    log "WARNING: This is a potentially dangerous operation."
    log "-----------------------------------------------------"
    read -p "Attempt emergency partition recreation? (y/n): " emergency
    
    if [ "$emergency" = "y" ]; then
      log "Starting emergency partition recreation..."
      
      # Unmount and close everything again
      umount -f "${dev}"* 2>/dev/null || true
      
      # Attempt to deactivate any existing LVM
      vgchange -an 2>/dev/null || true
      
      # Destroy the partition and recreate it
      log "Deleting partition 3..."
      parted -s "$dev" rm 3 || log "Warning: Failed to delete partition 3"
      
      # Make sure the partition table is reloaded
      partprobe "$dev" || true
      sleep 2
      
      # Recreate the partition
      log "Recreating LVM partition..."
      if $is_uefi; then
        parted -s "$dev" mkpart "lvm" ext4 "$((513 + $swap_size))MiB" 100%
      else
        parted -s "$dev" mkpart "lvm" ext4 "$((3 + $swap_size))MiB" 100%
      fi
      
      # Extra aggressive steps to ensure partition table is reloaded
      sync
      partprobe "$dev" || true
      udevadm settle
      sleep 10
      
      # Try all the methods to make the kernel recognize the new partition
      hdparm -z "$dev" 2>/dev/null || true
      blockdev --rereadpt "$dev" 2>/dev/null || true
      
      # Print current partition info for debugging
      log "Current partition information:"
      lsblk "$dev"
      
      # Try creating PV again on the newly created partition
      log "Attempting pvcreate on recreated partition..."
      pvcreate -ff "$lvm_part"
      
      if [ $? -ne 0 ]; then
        log "CRITICAL ERROR: All recovery methods failed."
        log "Manual intervention required:"
        log "You may need to reboot and start the installation again."
        log "After reboot, you might want to run 'dd if=/dev/zero of=$dev bs=1M count=100' to wipe the beginning of the disk completely before retrying."
        read -p "Press Enter to continue or Ctrl+C to abort..."
      else
        log "Emergency recovery successful. Continuing with volume group creation."
      fi
    else
      log "Emergency recovery skipped. Continuing with standard options..."
      
      log "Manual intervention required:"
      log "Try the following commands manually:"
      log "1. wipefs -a $lvm_part"
      log "2. pvcreate -ff $lvm_part"
      log "3. If successful, continue the script; otherwise reboot and try again"
      
      read -p "Would you like to run these commands now? (y/n): " run_manual
      if [ "$run_manual" = "y" ]; then
        log "Running wipefs to clean partition..."
        wipefs -a "$lvm_part"
        log "Retrying pvcreate with force flag..."
        pvcreate -ff "$lvm_part"
        if [ $? -ne 0 ]; then
          log "Manual commands failed. You may need to restart the system."
          read -p "Press Enter to continue or Ctrl+C to abort..."
        else
          log "Manual intervention successful. Continuing installation."
        fi
      else
        read -p "Press Enter to continue anyway (may fail) or Ctrl+C to abort..."
      fi
    fi
  else
    log "Automatic recovery successful. Continuing installation."
  fi
fi
check_success "Failed to create physical volume"

vgcreate vg_system "$lvm_part"
if [ $? -ne 0 ]; then
  log "ERROR: Failed to create volume group"
  log "Manual intervention required:"
  log "Try the following commands manually:"
  log "1. vgremove -f vg_system (if it exists)"
  log "2. pvremove $lvm_part"
  log "3. wipefs -a $lvm_part"
  log "4. pvcreate -ff $lvm_part"
  log "5. vgcreate vg_system $lvm_part"
  
  read -p "Would you like to run these commands now? (y/n): " run_manual_vg
  if [ "$run_manual_vg" = "y" ]; then
    log "Attempting to remove existing volume group..."
    vgremove -f vg_system 2>/dev/null || true
    log "Attempting to remove existing physical volume..."
    pvremove "$lvm_part" 2>/dev/null || true
    log "Running wipefs to clean partition..."
    wipefs -a "$lvm_part"
    log "Retrying pvcreate with force flag..."
    pvcreate -ff "$lvm_part"
    log "Retrying volume group creation..."
    vgcreate vg_system "$lvm_part"
    if [ $? -ne 0 ]; then
      log "Manual commands failed. You may need to restart the system."
      read -p "Press Enter to continue or Ctrl+C to abort..."
    else
      log "Manual intervention successful. Continuing installation."
    fi
  else
    read -p "Press Enter to continue anyway (may fail) or Ctrl+C to abort..."
  fi
fi
check_success "Failed to create volume group"

# Create logical volumes
log "Creating logical volumes..."
lvcreate -L 120G vg_system -n lv_root
check_success "Failed to create root logical volume"

lvcreate -l 100%FREE vg_system -n lv_home
check_success "Failed to create home logical volume"

# Format logical volumes
log "Formatting logical volumes..."
mkfs.ext4 /dev/vg_system/lv_root
check_success "Failed to format root partition"

mkfs.ext4 /dev/vg_system/lv_home
check_success "Failed to format home partition"

# Mount the partitions
log "Mounting the partitions..."
mount /dev/vg_system/lv_root /mnt
check_success "Failed to mount root partition"

mkdir -p /mnt/home
check_success "Failed to create home directory"

mount /dev/vg_system/lv_home /mnt/home
check_success "Failed to mount home partition"

if $is_uefi; then
  mkdir -p /mnt/boot/efi
  check_success "Failed to create efi directory"
  
  mount "$efi_part" /mnt/boot/efi
  check_success "Failed to mount EFI partition"
fi

swapon "$swap_part"
check_success "Failed to enable swap"

# Timezone configuration
log "Setting up timezone..."
regions=$(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d | sort)
PS3="Select region: "
select region in $regions; do
  if [ -n "$region" ]; then
    cities=$(find "$region" -maxdepth 1 -type f | sort)
    PS3="Select city: "
    select city in $cities; do
      if [ -n "$city" ]; then
        timezone=${city#/usr/share/zoneinfo/}
        break
      fi
    done
    break
  fi
done

log "Selected timezone: $timezone"

# Prepare package list
core_packages="base linux linux-firmware base-devel lvm2 sudo vim nano git reflector zsh networkmanager dhcpcd iwd"
cpu_packages="intel-ucode"
boot_packages=""
if $is_uefi; then
  boot_packages="grub efibootmgr"
else
  boot_packages="grub"
fi
gpu_packages="xorg xorg-server nvidia nvidia-utils nvidia-settings"
input_packages="xf86-input-libinput xf86-input-wacom"

# Update KDE Plasma packages - removed plasma-wayland-session as it may be integrated into plasma-meta
desktop_packages="plasma-meta plasma-pa plasma-nm konsole dolphin sddm kde-applications packagekit-qt5"

audio_packages="pipewire pipewire-pulse pipewire-alsa"
app_packages="firefox htop neofetch"
security_packages="ufw openssh fail2ban"
sharing_packages=""
if $install_sharing; then
  sharing_packages="nfs-utils samba boinc"
fi

# Construct package list
packages="$core_packages $cpu_packages $boot_packages $gpu_packages $input_packages $desktop_packages $audio_packages $app_packages $security_packages $sharing_packages"

# Install essential packages with better error handling
log "Installing essential packages..."
log "Package list: $packages"

# Try installing packages with retries and fallbacks
pacstrap_attempt=1
max_attempts=3
while [ $pacstrap_attempt -le $max_attempts ]; do
  log "Package installation attempt $pacstrap_attempt of $max_attempts"
  
  # Try without the potentially problematic packages first
  if [ $pacstrap_attempt -eq 1 ]; then
    if pacstrap /mnt $packages; then
      log "Successfully installed all packages"
      break
    else
      log "Failed to install all packages, will try with basic packages only"
    fi
  # Second attempt: Try with just the core system
  elif [ $pacstrap_attempt -eq 2 ]; then
    log "Trying to install base system only"
    if pacstrap /mnt base linux linux-firmware lvm2 sudo grub $boot_packages; then
      log "Base system installed, attempting to install remaining packages inside chroot"
      # Create a script to install remaining packages inside chroot
      cat > /mnt/install_remaining.sh << EOF
#!/bin/bash
pacman -Syu --noconfirm
# Try installing remaining packages in smaller groups
pacman -S --noconfirm $cpu_packages $gpu_packages $input_packages
pacman -S --noconfirm plasma-meta sddm konsole dolphin
pacman -S --noconfirm $audio_packages
pacman -S --noconfirm $app_packages
pacman -S --noconfirm $security_packages
pacman -S --noconfirm $sharing_packages
EOF
      chmod +x /mnt/install_remaining.sh
      arch-chroot /mnt /install_remaining.sh
      if [ $? -eq 0 ]; then
        log "Successfully installed remaining packages in chroot"
        break
      else
        log "Some packages failed to install in chroot, continuing anyway"
        break
      fi
    else
      log "Failed to install even the base system, trying minimal install"
    fi
  # Last attempt: Absolute minimum needed to boot
  else
    log "Trying minimal installation"
    if pacstrap /mnt base linux linux-firmware lvm2 grub $boot_packages; then
      log "Minimal system installed. You will need to install additional packages manually after boot"
      break
    else
      handle_error "Failed to install even the minimal system. Check your installation media and network connection."
    fi
  fi
  
  pacstrap_attempt=$((pacstrap_attempt + 1))
done

# Create a note about potential missing packages
if [ $pacstrap_attempt -gt 1 ]; then
  mkdir -p /mnt/etc/arch_setup
  cat > /mnt/etc/arch_setup/IMPORTANT_README.txt << EOF
IMPORTANT: Some packages failed to install during initial setup.
You may need to manually install the following packages after booting:
- Desktop environment: plasma-meta konsole dolphin kde-applications
- Graphics drivers: nvidia nvidia-utils
- Audio: pipewire pipewire-pulse
- Input drivers: xf86-input-libinput xf86-input-wacom
- Other utilities: firefox htop neofetch

If you see any error messages during boot or login, please run:
sudo pacman -Syu
sudo pacman -S plasma-meta sddm
sudo systemctl enable sddm
EOF
fi

check_success "Failed to install packages"

# Generate fstab
log "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
check_success "Failed to generate fstab"

# Chroot into the new system
log "Entering chroot environment..."
arch-chroot /mnt /bin/bash <<EOF
set -e

# Set timezone
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

# Localization
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Network configuration
echo "$hostname" > /etc/hostname
cat << EOL > /etc/hosts
127.0.0.1    localhost
::1          localhost
127.0.1.1    $hostname.localdomain $hostname
EOL

# Set root password
echo "root:${encrypted_root_password}" | chpasswd -e

# Create user
useradd -m -G wheel -s /bin/bash $username
echo "${username}:${encrypted_user_password}" | chpasswd -e

# Add user to necessary groups
usermod -aG video,audio,optical,storage,input $username

# Sudoers configuration
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Modify mkinitcpio.conf to include LVM
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block lvm2 filesystems fsck)/' /etc/mkinitcpio.conf

# Regenerate initramfs
mkinitcpio -P

# Install bootloader
if $is_uefi; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
  grub-install --target=i386-pc "$dev"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Enable NVIDIA DRM kernel mode setting
mkdir -p /etc/modprobe.d
echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf

# Setup network services
systemctl enable NetworkManager
systemctl enable dhcpcd
systemctl enable iwd

# Basic UFW setup
ufw default deny incoming
ufw default allow outgoing
ufw allow 2222/tcp comment "SSH"
if $install_sharing; then
  # NFS ports
  ufw allow 2049/tcp comment "NFS"
  # Samba ports
  ufw allow 137:139/tcp comment "Samba TCP"
  ufw allow 137:139/udp comment "Samba UDP"
  ufw allow 445/tcp comment "Samba TCP"
fi
ufw enable
systemctl enable ufw

# Configure SSH
sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl enable sshd

# Configure Fail2ban
cat << EOL > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = 2222
EOL
systemctl enable fail2ban

# Enable desktop and bluetooth
log "Enabling desktop services..."
if systemctl enable sddm; then
  log "SDDM enabled successfully"
else
  log "Warning: Failed to enable SDDM. Will attempt alternative method."
  # Make sure SDDM is installed
  if pacman -Sy --noconfirm sddm; then
    systemctl enable sddm
    log "SDDM installed and enabled"
  else
    log "Warning: Could not install or enable SDDM. You may need to enable it manually after boot."
    # Create a script to run after first boot to enable SDDM
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/enable-desktop.sh << 'DESKTOPSCRIPT'
#!/bin/bash
echo "Enabling SDDM display manager..."
# Update the system first
pacman -Syu --noconfirm
# Make sure SDDM is installed
if ! pacman -Q sddm &>/dev/null; then
  echo "Installing SDDM..."
  pacman -S --noconfirm sddm
fi
# Enable and start SDDM
systemctl enable sddm
systemctl start sddm
DESKTOPSCRIPT
    chmod +x /usr/local/bin/enable-desktop.sh
  fi
fi

if systemctl enable bluetooth; then
  log "Bluetooth enabled successfully"
else
  log "Warning: Failed to enable bluetooth. You may need to enable it manually after boot."
fi

# Create system directories specified in the full system spec
mkdir -p /etc/arch_setup
mkdir -p /var/log/arch_setup
mkdir -p /var/cache/arch_setup
mkdir -p /usr/local/lib/arch_setup
mkdir -p /mnt/backups
mkdir -p /mnt/shared
mkdir -p /var/lib/arch_setup
mkdir -p /etc/cloud-config

# Resource sharing configuration
if $install_sharing; then
  # NFS basic configuration
  cat << EOL > /etc/exports
# /mnt/shared *(rw,sync,no_subtree_check)
EOL
  systemctl enable nfs-server

  # Samba basic configuration
  cat << EOL > /etc/samba/smb.conf.new
[global]
   workgroup = WORKGROUP
   server string = Samba Server
   server role = standalone server
   log file = /var/log/samba/%m.log
   max log size = 50
   security = user
   passdb backend = tdbsam

# [shared]
#    path = /mnt/shared
#    browseable = yes
#    read only = no
#    guest ok = yes
EOL
  systemctl enable smb nmb

  # BOINC configuration
  systemctl enable boinc
fi

# Create temporary script to complete configuration after first boot
cat << 'POSTSCRIPT' > /usr/local/bin/zenbook-post-install.sh
#!/bin/bash

# Error handling
set -e
trap 'echo "Error occurred at line \$LINENO. Command: \$BASH_COMMAND"' ERR

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check and install packages
install_if_missing() {
    local package=$1
    log "Checking for package: $package"
    if ! pacman -Q $package &>/dev/null; then
        log "Installing missing package: $package"
        sudo pacman -S --noconfirm $package || log "Warning: Failed to install $package"
    fi
}

# Verify and install critical packages if missing
verify_critical_packages() {
    log "Verifying critical packages..."
    
    # Core KDE packages
    install_if_missing "plasma-meta"
    install_if_missing "sddm"
    install_if_missing "konsole"
    install_if_missing "dolphin"
    
    # Graphics
    install_if_missing "xorg-server"
    install_if_missing "nvidia"
    install_if_missing "nvidia-utils"
    
    # Input
    install_if_missing "xf86-input-libinput"
    install_if_missing "xf86-input-wacom"
    
    # Audio
    install_if_missing "pipewire"
    install_if_missing "pipewire-pulse"
    
    # Check if KDE Plasma is properly installed
    if ! pacman -Q plasma-desktop &>/dev/null; then
        log "KDE Plasma appears to be missing. Attempting to install..."
        sudo pacman -Syu --noconfirm
        sudo pacman -S --noconfirm plasma-desktop plasma-pa plasma-nm
    fi
    
    # Ensure desktop environment is enabled
    if ! systemctl is-enabled sddm &>/dev/null; then
        log "Enabling SDDM..."
        sudo systemctl enable sddm
    fi
}

# Install AUR helper (yay)
if ! command -v yay &>/dev/null; then
    log "Installing yay (AUR helper)..."
    cd /tmp
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ~
fi

# Verify critical packages first
verify_critical_packages

# Function to setup Optimus Manager with fallback
setup_optimus() {
    log "Setting up NVIDIA Optimus management..."
    if ! yay -S --noconfirm optimus-manager; then
        log "Failed to install optimus-manager. Falling back to basic PRIME configuration."
        sudo pacman -S --noconfirm nvidia-prime
        log "Basic PRIME setup completed. Use prime-run to run applications with NVIDIA GPU."
        return
    fi
    
    # Configure optimus-manager to use Intel by default
    sudo mkdir -p /etc/optimus-manager
    echo "[optimus]" | sudo tee /etc/optimus-manager/optimus-manager.conf
    echo "startup_mode=integrated" | sudo tee -a /etc/optimus-manager/optimus-manager.conf
    echo "switching_mode=bbswitch" | sudo tee -a /etc/optimus-manager/optimus-manager.conf
    
    # Enable and start the service
    sudo systemctl enable optimus-manager
    sudo systemctl start optimus-manager
    
    log "Optimus Manager setup completed successfully."
}

# Generate SSH key if it doesn't exist
if [ ! -f ~/.ssh/id_ed25519 ]; then
    log "Generating SSH key..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
    log "SSH key generated: ~/.ssh/id_ed25519.pub"
fi

# Install optimus-manager for GPU switching
setup_optimus

# Install additional touch screen and stylus support
log "Setting up touch screen and stylus support..."
sudo pacman -S --noconfirm xf86-input-libinput xf86-input-wacom xournalpp
yay -S --noconfirm touchegg || log "Warning: Failed to install touchegg, continuing..."

# Install font improvements
log "Improving fonts..."
sudo pacman -S --noconfirm ttf-dejavu ttf-liberation ttf-droid ttf-roboto noto-fonts

# Configure font rendering
sudo mkdir -p /etc/fonts
cat << EOF | sudo tee /etc/fonts/local.conf
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
    <match target="font">
        <edit mode="assign" name="antialias">
            <bool>true</bool>
        </edit>
        <edit mode="assign" name="hinting">
            <bool>true</bool>
        </edit>
        <edit mode="assign" name="hintstyle">
            <const>hintfull</const>
        </edit>
        <edit mode="assign" name="lcdfilter">
            <const>lcddefault</const>
        </edit>
        <edit mode="assign" name="rgba">
            <const>rgb</const>
        </edit>
    </match>
</fontconfig>
EOF

# Update font cache
sudo fc-cache -fv

# System optimizations
log "Applying system optimizations..."
sudo sysctl -w net.core.rmem_max=2500000
sudo sysctl -w net.core.wmem_max=2500000
sudo sysctl -w net.ipv4.tcp_rmem='4096 87380 2500000'
sudo sysctl -w net.ipv4.tcp_wmem='4096 65536 2500000'
sudo sysctl -w vm.swappiness=20

# Make these optimizations persistent
cat << EOF | sudo tee /etc/sysctl.d/99-network-performance.conf
net.core.rmem_max=2500000
net.core.wmem_max=2500000
net.ipv4.tcp_rmem=4096 87380 2500000
net.ipv4.tcp_wmem=4096 65536 2500000
vm.swappiness=20
EOF

# Create Obsidian vault directory structure
mkdir -p ~/obsidian-vault/system-config/machines
mkdir -p ~/obsidian-vault/system-config/backups
mkdir -p ~/obsidian-vault/scripts
mkdir -p ~/obsidian-vault/system-config/sharing

# Create basic configuration for this machine
cat << EOF > ~/obsidian-vault/system-config/machines/$HOSTNAME.md
---
hostname: $HOSTNAME
extends: base.md
swappiness: 20
---
# $HOSTNAME Configuration
- ASUS ZenBook Q528EH
- Intel Core i7-1165G7
- 16GB RAM
- NVIDIA GeForce GTX 1650 Max-Q
- Intel Iris Xe Graphics
EOF

# Create base configuration
cat << EOF > ~/obsidian-vault/system-config/base.md
---
hostname: base
packages:
  - base
  - linux
  - linux-firmware
  - networkmanager
  - dhcpcd
  - iwd
  - ufw
  - openssh
  - lvm2
---
# Base Configuration
- Base system configuration for all machines
- Core packages and services
- Network management with NetworkManager, dhcpcd, and iwd
- Security with UFW and SSH (port 2222)
- LVM for storage management
EOF

# Create resource sharing configuration
cat << EOF > ~/obsidian-vault/system-config/sharing.md
---
hostname: base
packages:
  - nfs-utils
  - samba
  - boinc
---
# Resource Sharing Configuration
- NFS for Unix/Linux file sharing
- Samba for Windows file sharing
- BOINC for distributed computing
- All services share data through /mnt/shared
EOF

# Final system check
log "Performing final system check..."

# Check if desktop environment is installed
if ! pacman -Q plasma-desktop &>/dev/null; then
    log "WARNING: KDE Plasma desktop is not installed correctly."
    log "After rebooting, login to the console and run:"
    log "sudo pacman -Syu"
    log "sudo pacman -S plasma-meta sddm"
    log "sudo systemctl enable sddm"
    log "sudo systemctl start sddm"
fi

# Verify NVIDIA drivers
if ! pacman -Q nvidia &>/dev/null; then
    log "WARNING: NVIDIA drivers are not installed correctly."
    log "You may experience graphics issues."
    log "To install after reboot, run:"
    log "sudo pacman -S nvidia nvidia-utils"
fi

log "Post-installation setup complete!"
log "Please log out and log back in for some changes to take effect."

# Remove this script after execution
read -p "Press Enter to exit post-installation setup..."
sudo rm /usr/local/bin/zenbook-post-install.sh
sudo rm /etc/profile.d/zenbook-post-install.sh
POSTSCRIPT

chmod +x /usr/local/bin/zenbook-post-install.sh

# Create auto-start script for first login
mkdir -p /etc/profile.d
cat << EOF > /etc/profile.d/zenbook-post-install.sh
#!/bin/bash
if [ "\$USER" = "$username" ]; then
    if [ -f /usr/local/bin/zenbook-post-install.sh ]; then
        echo "Running post-installation setup..."
        bash /usr/local/bin/zenbook-post-install.sh
    fi
fi
EOF

chmod +x /etc/profile.d/zenbook-post-install.sh

# Add desktop enablement to post-install if needed
if ! systemctl is-enabled sddm &>/dev/null; then
  echo "# Enable desktop if needed" >> /usr/local/bin/zenbook-post-install.sh
  echo "if ! systemctl is-enabled sddm &>/dev/null; then" >> /usr/local/bin/zenbook-post-install.sh
  echo "  sudo /usr/local/bin/enable-desktop.sh" >> /usr/local/bin/zenbook-post-install.sh
  echo "fi" >> /usr/local/bin/zenbook-post-install.sh
fi

EOF

# Check if chroot script executed successfully
if [ $? -ne 0 ]; then
  handle_error "Chroot script failed. See above for errors."
fi

# Unmount all partitions
log "Unmounting partitions..."
umount -R /mnt || log "Warning: Failed to unmount all partitions"

log "Installation completed successfully!"
log "System will now reboot."
log "After reboot, the post-installation setup will run automatically on first login."
read -p "Press Enter to reboot..."

reboot 