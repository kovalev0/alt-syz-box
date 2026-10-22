# Unit-tests targets

This directory drives the unit-tests flow (`./run-all.sh unit-tests`, implemented
by `scripts/06-run-unit-tests.sh`). It builds each out-of-tree kernel module
against a **gcov-instrumented** kernel, runs its tests inside the QEMU guest, and
collects line coverage for the module.

## Layout

- `targets/*.conf` — one file per module (the *catalog*). Every `.conf` here is
  picked up automatically. To disable a target, remove or rename its file (drop
  the `.conf` suffix), or restrict the run with `TARGETS="name1 name2"`.
- `tests/*.sh` — the in-guest test drivers, shipped into the VM and run as root.

## Target contract (`targets/<name>.conf`)

Each `.conf` is a small bash fragment, sourced by the orchestrator with
`$KERNEL_BUILD_DIR` pointing at the gcov kernel build and `$TARGET_SRC` set to
the freshly cloned source tree. It must define:

| Variable | Meaning |
|---|---|
| `TARGET_NAME` | short identifier (used for report/work dirs) |
| `TARGET_GIT_URL` | git URL of the module sources |
| `TARGET_GIT_REF` | branch or tag to check out (e.g. `p11`) |
| `TARGET_COV_PATTERN` | `lcov --extract` pattern; scopes the report to this module |
| `TARGET_GUEST_TEST` | driver filename under `tests/`, run in the guest as root |
| `TARGET_KCONFIG` | kernel symbols the module needs; enabled in the gcov build |

and one function:

- `target_build` — builds the module(s) against `$KERNEL_BUILD_DIR`, leaving the
  `.ko` **and** the `.gcno` in `$TARGET_SRC`. It may also build userspace helpers
  (e.g. `libxt_so.so`, `iptaccount`) into `$TARGET_SRC`.

Coverage works because `CONFIG_GCOV_PROFILE_ALL` instruments everything built
against the kernel, including out-of-tree modules; the guest exposes the counters
under `/sys/kernel/debug/gcov/<build-path>` once the module is loaded and run.
If a module's `.gcda` never appear, add `GCOV_PROFILE := y` to its Kbuild.

## What the orchestrator does per target

1. clone `TARGET_GIT_URL@TARGET_GIT_REF` into `$UNIT_TESTS_DIR/<name>/src`;
2. run `target_build`;
3. boot the guest, reset gcov counters;
4. copy the built source tree and the guest driver in, run the driver as root;
5. tar the debugfs gcov subtree, pull it back, power the VM off;
6. merge `.gcno` + `.gcda`, extract `TARGET_COV_PATTERN`, render HTML into
   `$UNIT_TESTS_DIR/<name>/reports/`.

## TARGET_COVERAGE_MODE

Optional; defaults to `module`. Selects how a target's coverage is collected:

- `module` (default) — out-of-tree **kernel module**. Its `.gcda` are read from
  the kernel gcov debugfs (`/sys/kernel/debug/gcov<build-path>`) and paired with
  the build `.gcno`. Used by `dm-secdel`, `ipt-so`, `tripso`, `xtables-addons`.
- `kernel` — full-kernel gcov (needs `TARGET_KCONFIG="GCOV_PROFILE_ALL"`). The
  whole gcov debugfs tree is pulled and each `.gcda` paired with the matching
  kernel `.gcno`. Used by `kselftests`.
- `userspace` — out-of-tree **userspace** program built with `gcc --coverage`.
  There is nothing in the kernel gcov debugfs; instead the instrumented binaries
  write their `.gcda` to the filesystem at exit via libgcov. The in-guest driver
  redirects those writes to `$GCOV_USERSPACE_DIR` (see `scripts/lib/gcov-lib.sh`)
  by exporting `GCOV_PREFIX`/`GCOV_PREFIX_STRIP`; the orchestrator pulls that
  directory and pairs the `.gcda` with the build `.gcno`. Used by `secure_delete`,
  `iptables` and `cryptsetup`.

For a `userspace` target, `target_build` must compile the sources **with
`--coverage`** (so the `.gcno` and instrumented binaries land in `$TARGET_SRC`),
and the guest driver must set `GCOV_PREFIX=$GCOV_USERSPACE_DIR`.
`GCOV_PREFIX_STRIP` then decides where each `.gcda` lands:

- **single-directory** sources (all objects in one dir, e.g. `secure_delete`):
  strip everything (`GCOV_PREFIX_STRIP=99`) so the `.gcda` sit flat next to the
  flat `.gcno` — see `targets/secure_delete.conf` / `tests/secure_delete.sh`.
- **multi-directory** sources (autotools trees with `lib/`, `src/`, `extensions/`
  …, e.g. `iptables`, `cryptsetup`): flattening would collide on basenames, so the
  layout must be preserved. `target_build` records the absolute host build root in
  `$TARGET_SRC/.gcov-build-root`, and the driver sets `GCOV_PREFIX_STRIP` to that
  path's component count. libgcov then reproduces the build tree under
  `$GCOV_PREFIX` at paths **relative to `$TARGET_SRC`**, matching the `.gcno` so
  `gcov_report()` pairs them — see `targets/iptables.conf` / `tests/iptables.sh`.

Build notes for autotools userspace packages (see `targets/iptables.conf`):

- **BuildRequires in the container.** The package needs its `-devel`
  dependencies present to configure/build; the alt-syz-box container does not
  ship them, so `target_build` installs them itself (`apt-get`, idempotent),
  taken from the package's ALT spec, then configures with the **spec's own
  options** (only adding `--coverage`/`-O0`) so the build stays close to release.
- **Static binaries.** Build with `--disable-shared --enable-static` even if the
  spec uses shared libs. A shared libtool build emits the program as a wrapper
  SCRIPT that, run before `make install` from another directory, cd-s into the
  original (host) build path and relinks — which fails in the guest. Static
  linking yields real, relocatable ELF binaries; objects (and thus coverage) are
  identical.
- **Reuse the suite.** Prefer the package's **own `make check` TESTS** over
  hand-written tests. See also `targets/cryptsetup.conf`, which builds the C test
  programs (`make -C tests check-programs`) on the host so the guest needs no
  compiler.

## TARGET_NETFILTER

Set `TARGET_NETFILTER=1` in a target's `.conf` when the module needs a realistic
netfilter kernel. If any enabled target sets it, the shared symbol list
`config/unit-tests/netfilter-kconfig.list` is added to the kernel configuration
(on top of each target's own `TARGET_KCONFIG`).

## Per-target source patches

Patches under `patches/unit-tests/<target>/*.patch` are applied to a target's
checked-out sources before building (same idea as `patches/kernel`,
`patches/qemu`, `patches/syzkaller`). Use them to fix bugs in the module sources
— e.g. the xtables-addons `xt_quota2`/`xt_DELUDE` kernel-crash fixes ship this
way. Patches are kernel-style (produced with `git format-patch`) and applied with
`git apply`.
