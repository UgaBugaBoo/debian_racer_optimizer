# Debian/Ubuntu Server Optimizer for High-Speed Torrenting

An interactive Bash script designed to tune and optimize a Debian-based Linux system (like Debian or Ubuntu) for high-speed torrenting, particularly for torrent racing on servers with gigabit or faster network connections.

This tool prioritizes safety and user experience, providing clear explanations, creating backups before making changes, and offering a menu-driven interface.

**Author:** Sabbir Bin Anis  
**License:** [MIT License](LICENSE)

---

## 🚨 Disclaimer

This script modifies critical system configuration files. While it includes safety measures like creating backups, **you are running it at your own risk.** The author is not responsible for any data loss, system instability, or other issues that may arise from its use. **Always have a complete system backup before making significant changes.**

---

## Features

- **Interactive Menu:** A clear, user-friendly menu to apply tweaks individually or all at once.
- **Safety First:** Automatically creates timestamped backups of any configuration file it modifies.
- **Idempotent:** Safe to run multiple times; it won't create duplicate configuration entries.
- **Dependency Checks:** Automatically checks for and offers to install required utilities like `cpufrequtils` and `procps`.
- **Clear Explanations:** Explains what each tweak does and why it's beneficial before applying it.
- **Color-Coded Output:** Uses colors to differentiate between information, warnings, successes, and errors.

### Optimizations Applied

- **Network Stack (sysctl):**
  - Enables TCP BBR congestion control with the FQ packet scheduler.
  - Massively increases TCP/UDP memory buffers for 1Gbps+ speeds.
  - Increases the connection tracking table size (`nf_conntrack_max`).
  - Increases the maximum SYN backlog to handle more simultaneous connection attempts.
  - Lowers `vm.swappiness` to prioritize RAM usage over disk swap.
- **Disk I/O:**
  - Detects drive type (SSD/NVMe vs. HDD).
  - Sets the optimal I/O scheduler (`none` for SSD/NVMe, `mq-deadline` for HDD) via a persistent `udev` rule.
- **CPU Performance:**
  - Sets the CPU governor to `performance` for maximum clock speed and reduced latency.
- **System Limits:**
  - Increases the system-wide open file descriptor limit (`ulimit -n`) to prevent "Too many open files" errors.

---

## How to Use

### Step 1: Download the Script

Save the script to your server. A good name would be `optimizer.sh`.

```bash
# Example using curl
curl -O https://your-repository-url/optimizer.sh
```

### Step 2: Make the Script Executable

```bash
chmod +x optimizer.sh
```

### Step 3: Run the Script (Based on Your Environment)

The usage depends on your system environment. Follow the procedure that matches your setup.

#### A) Procedure for Standard Systems (Bare-Metal, KVM, VMware, etc.)

If your Debian/Ubuntu OS has direct control over its kernel, this is the procedure for you.

Run the script with `sudo`:

```bash
sudo ./optimizer.sh
```

From the main menu, choose option 5 to `Check & Apply ALL Recommended Tweaks`.

Confirm the prompts. The script will apply all optimizations.

When it's finished, reboot the system to ensure all changes take effect.

```bash
sudo reboot
```

Your system is now fully optimized.

#### B) Procedure for Proxmox LXC Containers

In an LXC container, the OS does not have direct control over the kernel. The process is split between the container and the Proxmox Host.

##### Part 1: Inside the LXC Container

Enter your LXC container:

```bash
pct enter <YOUR_CT_ID>
```

Run the script inside the container:

```bash
sudo ./optimizer.sh
```

Choose option 5. The script will successfully apply some tweaks (like file limits) but will show expected errors/warnings when it fails to apply the network `sysctl` settings. This is normal.

Exit the container.

##### Part 2: On the Proxmox Host

**Enable Required Kernel Modules:**

Log into your Proxmox Host's shell and run the following commands to enable BBR and FQ.

```bash
# Load for current session
modprobe tcp_bbr
modprobe sch_fq

# Make them persistent across host reboots
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
echo "sch_fq" > /etc/modules-load.d/fq.conf
```

**Apply Kernel Settings on the Host:**

Create a configuration file on the host to apply the network tunings.

```bash
nano /etc/sysctl.d/99-lxc-custom-tuning.conf
```

Paste the following into the file:

```ini
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.tcp_max_syn_backlog = 8192
vm.swappiness = 10
```

Save the file (Ctrl+X, Y, Enter).

**Activate the Host Settings:**

```bash
sysctl --system
```

**Reboot the LXC Container:**

The container needs to be restarted to inherit the new host kernel settings.

```bash
pct reboot <YOUR_CT_ID>
```

Your container is now fully optimized.

---

## Contributing

Feel free to open an issue or submit a pull request if you have suggestions for improvements or find any bugs.
