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
