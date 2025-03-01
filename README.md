# Arch Linux Setup for ASUS ZenBook Q528EH

This repository contains automated installation scripts for setting up Arch Linux on an ASUS ZenBook Q528EH laptop.

## Features

- UEFI boot with GRUB (with BIOS fallback option)
- Partitioning: EFI (512MB), Swap (auto-sized), LVM (remainder)
- LVM Configuration: Root (120GB), Home (remainder)
- KDE Plasma desktop environment
- NVIDIA + Intel hybrid graphics with optimus-manager
- Touchscreen and stylus support
- Resource sharing capabilities (NFS, Samba, BOINC, SLURM)
- Basic security configuration with UFW and SSH

## Usage

```bash
# Run as root
sudo ./install_zenbook_q528eh.sh
```

## Warning

This script will erase data on the selected disk. Make sure you have backed up your important data before proceeding.

## License

MIT 