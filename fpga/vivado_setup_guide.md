# Vivado 2024.2 Installation & Setup Guide (Ubuntu 24.04 / PYNQ-Z2)

This guide documents the setup process for installing **AMD Vivado ML Standard 2024.2** on **Ubuntu 24.04 LTS** for the **PYNQ-Z2** (Zynq-7000) FPGA board.

---

## 1. System Dependencies (Ubuntu 24.04)

Before running the installer, install required system build tools and graphical libraries:

```bash
sudo apt update
sudo apt install -y \
  build-essential \
  libtinfo6 \
  libncurses6 \
  libncurses5-dev \
  libxtst6 \
  libxi6 \
  libxrender1 \
  libxrandr2 \
  libfontconfig1 \
  libfreetype6 \
  libxcursor1 \
  libxinerama1 \
  libgl1 \
  libgtk2.0-0 \
  git \
  curl
```

---

## 2. Download the Web Installer

1. Navigate to the [AMD Vivado Downloads Page](https://www.xilinx.com/support/download.html).
2. Select **Vivado 2024.2**.
3. Download the **AMD Unified Installer for FPGAs & Adaptive SoCs 2024.2: Linux Self Extracting Web Installer** (`.bin` file, ~300 MB).

---

## 3. Run & Configure the Installer

1. Make the downloaded `.bin` file executable and run it:
   ```bash
   cd ~/Downloads
   chmod +x FPGAs_AdaptiveSoCs_Unified_2024.2_*_Lin64.bin
   ./FPGAs_AdaptiveSoCs_Unified_2024.2_*_Lin64.bin
   ```
2. **Login:** Enter your AMD account credentials to authenticate.
3. **Product Selection:** Select **Vivado**.
4. **Edition:** Select **Vivado ML Standard** (Free / No license required).
5. **Customize Installation (Crucial to minimize disk footprint):**
   - **Design Tools:**
     - [x] **Vivado** (Required)
     - [ ] **Vitis HLS** (Uncheck)
     - [ ] **Vitis Model Composer** (Uncheck)
     - [x] **DocNav** (Optional)
   - **Devices:**
     - [ ] **Install Devices for Kria SOMs and Starter Kits** (Uncheck)
     - [x] **Production Devices -> SoCs -> Zynq-7000** (Check)
     - [x] **Production Devices -> 7 Series** (Check)
     - [ ] **UltraScale / UltraScale+ / Versal** (Uncheck)
6. **Destination Directory & Shortcuts:**
   - Set destination to your user home directory: `~/Xilinx` (e.g. `/home/<user>/Xilinx`) to avoid root permission issues.
   - Keep **Create program group entries** checked (adds Vivado to Ubuntu application drawer).
   - Keep **Create desktop shortcuts** checked.
7. Click **Install** and wait for the download and installation to complete.

---

## 4. Post-Installation Steps

### A. Install Cable Drivers (JTAG / UART Detection)
Run the driver installation script with root privileges:

```bash
cd ~/Xilinx/Vivado/2024.2/data/xicom/cable_drivers/lin64/install_script/install_drivers/
sudo ./install_drivers
```

### B. Add Terminal Shortcut
Add a convenient startup alias to your `~/.bashrc`:

```bash
echo "alias vivado='source ~/Xilinx/Vivado/2024.2/settings64.sh && vivado &'" >> ~/.bashrc
source ~/.bashrc
```

### C. Install PYNQ-Z2 Board Definition Files
1. Launch Vivado from terminal:
   ```bash
   vivado
   ```
2. In the **Tcl Console** at the bottom of the Vivado window, run:
   ```tcl
   xhub::refresh_catalog [xhub::get_xstores xilinx_board_store]
   xhub::install [xhub::get_xitems *pynq-z2*]
   ```

Vivado is now configured and ready for PYNQ-Z2 hardware design and bitstream generation.

