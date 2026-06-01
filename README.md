# alt-syz-box

A flexible and extensible environment for fuzzing Linux kernels with syzkaller, optimized for ALT Linux distributions but configurable for any kernel.

This repository provides a CLI-driven, Docker-based workflow to build, configure, and run the syzkaller fuzzer.

**Features**:
-   **Centralized Configuration**: Key settings like names and ports are in `project.env`.
-   **Modular Execution**: A powerful `run-all.sh` script to control each stage of the process.
-   **Flexible Scripting**: Most scripts accept arguments to override defaults.
-   **Comprehensive Tooling**: Includes helpers for VM management, monitoring, and artefact collection.

---

## Directory Structure

```
alt-syz-box/
├── build-docker-image.sh
├── collect-artefacts.sh
├── config/
│   └── syzkaller/
│       ├── generic.config.template
│       ├── example.config.template
│       └── ...
├── Dockerfile
├── enter-container.sh
├── LICENSE
├── monitor-fuzzer.sh
├── patches/
│   ├── kernel/
│   │   └── ...*.patch
│   ├── qemu/
│   │   └── ...*.patch
│   └── syzkaller/
│       └── ...*.patch
├── project.env
├── README.md
├── run-all.sh
├── run-container.sh
├── scripts/
│   ├── 01-setup-env.sh
│   ├── 02-build-kernel.sh
│   ├── 03-build-qemu.sh
│   ├── 04-build-syzkaller.sh
│   ├── 05-build-image.sh
│   ├── run-vm.sh
│   ├── scp-from-vm.sh
│   ├── scp-to-vm.sh
│   ├── ssh-to-vm.sh
│   ├── start-fuzzer.sh
│   └── tools/*
└── stop-fuzzer.sh
```

---

## 1. Initial Configuration

Before you begin, you can review and edit the default settings in these two files:

1.  **`project.env`**: Contains default names for the Docker image and container, network ports.
2.  **`scripts/01-setup-env.sh`**: Contains settings for the fuzzing process itself, such as the kernel git repository, branch, and syzkaller configuration template.

---

## 2. Main Workflow

The `run-all.sh` script is the main entry point for most operations.

### Automated Full Run

To build the image, start the container, run all setup scripts, and launch the fuzzer in the background, simply run:

```bash
./run-all.sh
```

This is equivalent to running `./run-all.sh all`.

### Stage-by-Stage Execution

You can also run each major stage individually. This is useful for development and debugging.

```bash
# Build the Docker image
./run-all.sh build

# Start the container
./run-all.sh container

# Run all setup scripts (kernel, qemu, syzkaller, image)
./run-all.sh setup

# Or run a specific setup step
./run-all.sh kernel
./run-all.sh qemu
./run-all.sh syzkaller
./run-all.sh image

# Start the fuzzer
./run-all.sh fuzzer
```

## 3. Manual Usage

For more fine-grained control, you can use the individual scripts.

### Build and Run

You can override the default image and container names.

```bash
# Build with a custom image name
./build-docker-image.sh my-custom-fuzzer:v1

# Run with custom container and image names
./run-container.sh my-fuzzer-instance my-custom-fuzzer:v1
```

### Interacting with the Container

```bash
# Get an interactive shell inside the container
./enter-container.sh

# Monitor the fuzzer's log output
./monitor-fuzzer.sh

# Stop the running syz-manager process
./stop-fuzzer.sh
```

## 4. VM Management (for Debugging)

Scripts are provided to run a standalone QEMU VM for manual testing or reproducing crashes.

```bash
# Run a VM (SSH on default port 22000)
# This command must be run from inside the container
~/alt-syz-box/scripts/run-vm.sh

# or outside

docker exec -it alt-syz-box-container ./scripts/run-vm.sh

# Run a VM with a custom SSH port
docker exec -it alt-syz-box-container ./scripts/run-vm.sh -p 2222

# --- From your host machine, in another terminal: ---

# SSH into the running VM
~/alt-syz-box/scripts/ssh-to-vm.sh -p 2222

# Copy a file TO the VM
~/alt-syz-box/scripts/scp-to-vm.sh -p 2222 ./local-file.txt /root/

# Copy a directory FROM the VM
~/alt-syz-box/scripts/scp-from-vm.sh -p 2222 /root/crashes ./
```

## 5. Artefact Collection

`collect-artefacts.sh` — full collection (run on host)

Runs the collection pipeline inside the container via `docker exec`. The resulting
archive is placed in the container's syzkaller workdir, which is mounted to
`./volume/workdir-<config>/` on the host and accessible immediately after the script
finishes.

```bash
# Collect crashes, corpus, configs, coverage and log
./collect-artefacts.sh

# Also include vmlinux and rawcover (needed for addr2line post-processing)
./collect-artefacts.sh --with-rawcover

# Trim repeated log/report/machineInfo files to 3 most recent per crash dir
./collect-artefacts.sh --trim-crashes

# Also generate crash_analysis_table_<TIMESTAMP>.ods alongside the archive
# (not inside — the spreadsheet is meant to be hand-edited during analysis)
./collect-artefacts.sh --with-analysis-table

# Also save the syz-manager main page (Expert mode) as
# syzmanager_page_<TIMESTAMP>.html for manual screenshotting
./collect-artefacts.sh --with-page-snapshot
```

The archive `artefacts_<TIMESTAMP>.tar.xz` contains:

```
artefacts_<TIMESTAMP>/
  crashes/                   syz-manager crash directories
  corpus.db                  corpus database
  fuzzing.log                syz-manager log (/tmp/alt-syz-box.log)
  configs/
    config.json              desired syzkaller config (template-generated)
    linux-<HASH>             kernel .config (hash = kernel git HEAD)
    syzkaller-<HASH>         actual running syzkaller config (hash = syzkaller git HEAD)
  coverage/
    index.html               browsable HTML coverage report
  vmlinux                    kernel debug binary      (only with --with-rawcover)
  rawcover                   raw PC coverage          (only with --with-rawcover)
```

`scripts/tools/gen-crashes-table.py` — analysis table (inside container)

Generates `crash_analysis_table.ods` from the running syz-manager main page.
The spreadsheet is meant to be embedded as an OLE object into the fuzzing
report `.odt`. Cells are color-coded by value (live conditional formatting),
analyst-facing columns have dropdowns with autocomplete, and a summary block
with live `COUNTIF` formulas plus a legend of allowed values are appended.

```bash
# Default: fetch from http://localhost:56741/ (internal port)
./scripts/tools/gen-crashes-table.py

# From a saved HTML page (no live syz-manager needed)
./scripts/tools/gen-crashes-table.py -i /tmp/main.html -o my.ods
```

`scripts/tools/save-syzmanager-page.sh` — UI snapshot (inside container)

Saves the syz-manager main page with Expert mode toggled on into a single
`syzmanager_page_<TIMESTAMP>.html` file, ready to be opened in any browser
and screenshotted by hand. Requires only `curl`; no headless renderer needed.

```bash
# Default: fetch from http://localhost:56741/ (internal port)
./scripts/tools/save-syzmanager-page.sh

# Custom output file
./scripts/tools/save-syzmanager-page.sh -o /tmp/snapshot.html
```

`scripts/tools/collect-coverage.sh` — coverage only (inside container)

Fetches the HTML coverage page from syz-manager and saves it to a local directory.

```bash
# Default output: $SYZKALLER_WORKDIR/coverage_<TIMESTAMP>/
./scripts/tools/collect-coverage.sh

# Custom output directory
./scripts/tools/collect-coverage.sh -o /tmp/my-coverage
```

---

## License
This project is licensed under the GNU General Public License v3.0. See the LICENSE file for details.
