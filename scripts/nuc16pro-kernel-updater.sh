#!/usr/bin/env bash
set -euo pipefail

OWNER_REPO="${OWNER_REPO:-AmirulAndalib/asus-nuc16pro-cachyos-server-edge-kernel}"

STATE_DIR="/var/lib/nuc16pro-kernel-updater"
LOG_DIR="/var/log/nuc16pro-kernel-updater"
WORK_DIR="/tmp/nuc16pro-kernel-install"
LOCK_FILE="/run/nuc16pro-kernel-updater.lock"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$WORK_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "another instance is already running"
  exit 0
fi

LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

msg() { echo ":: $*"; }

# Keep newest installed cachyos-nuc16pro kernel + currently running kernel.
# Purge all other cachyos-nuc16pro image and header packages.
# Must run before update-initramfs to avoid regenerating for kernels about to be removed.
purge_old_custom_kernels() {
  local target_kver="$1"
  msg "purging old custom kernels"

  mapfile -t ALL_CUSTOM_IMG < <(
    dpkg -l | awk '/^ii/ && /linux-image-.*cachyos.*nuc16pro/ {print $2}' | sort -V
  )

  if [ "${#ALL_CUSTOM_IMG[@]}" -le 1 ]; then
    echo "  only ${#ALL_CUSTOM_IMG[@]} custom kernel installed, nothing to purge"
    return 0
  fi

  # Keep the kernel that matches the current release version, not the highest sort order.
  # RC kernels (e.g. 7.1.0-rc2) sort higher than stable (7.0.10) but are not the target.
  KEEP_TARGET=""
  for pkg in "${ALL_CUSTOM_IMG[@]}"; do
    if echo "$pkg" | grep -qF "$target_kver"; then
      KEEP_TARGET="$pkg"
      break
    fi
  done
  [ -z "$KEEP_TARGET" ] && KEEP_TARGET="${ALL_CUSTOM_IMG[-1]}"

  RUNNING_PKG="linux-image-$(uname -r)"

  PKGS_TO_PURGE=()
  for pkg in "${ALL_CUSTOM_IMG[@]}"; do
    if [ "$pkg" = "$KEEP_TARGET" ]; then
      echo "  keep (target):  $pkg"
      continue
    fi
    if [ "$pkg" = "$RUNNING_PKG" ]; then
      echo "  keep (running): $pkg"
      continue
    fi
    PKGS_TO_PURGE+=("$pkg")
    HDR="${pkg/linux-image-/linux-headers-}"
    if dpkg -l "$HDR" 2>/dev/null | grep -q '^ii'; then
      PKGS_TO_PURGE+=("$HDR")
    fi
  done

  if [ "${#PKGS_TO_PURGE[@]}" -eq 0 ]; then
    echo "  nothing to purge"
    return 0
  fi

  echo "  purging: ${PKGS_TO_PURGE[*]}"
  apt-get purge -y "${PKGS_TO_PURGE[@]}" || true
}

msg "nuc16pro kernel updater"
date
uname -a

msg "ensuring tools"
apt-get update -qq
apt-get install -y curl jq ca-certificates ethtool lm-sensors

msg "ensuring media (VA-API) + diagnostic userspace"
# The kernel alone does not provide VA-API: hardware transcode needs the Intel iHD userspace
# media driver, validated 2026-07 (vainfo failed with "va_openDriver() returns -1" until these
# were installed). Kept in a SEPARATE, non-fatal apt call so an unavailable package on a given
# release degrades gracefully instead of aborting the kernel install. Deliberately NOT installing
# intel-gsc: it is absent from the Ubuntu 26.04 repos and, bundled into one transaction, aborts
# the whole install (apt validates the full package list up front, so one missing name kills it).
# GSC firmware loads kernel-side from xe/ptl_gsc_1.bin regardless of this userspace package.
# smartmontools + nvme-cli back the post-boot health-check's drive-SMART section.
# mesa-vulkan-drivers ships the lavapipe (lvp_icd.json) software Vulkan ICD that the
# RDP software-Vulkan workaround below pins gnome-remote-desktop to on Xe3.
apt-get install -y \
  intel-media-va-driver-non-free libigdgmm12 libmfx-gen1.2 libvpl-tools vainfo \
  smartmontools nvme-cli mesa-vulkan-drivers \
  || echo "warn: some media/diagnostic packages unavailable on this release, continuing"

msg "fetching latest release"
# Use list endpoint, not /releases/latest, so RC prereleases are included.
# Exclude the scx-* stream: this repo publishes both kernel and scx-scheduler
# releases, so a plain .[0] grabs whichever published most recently. A fresh
# scx-* release would then be misread as the kernel release (no linux-image
# asset -> hard fail until the next kernel release lands, possibly weeks out).
# Mirrors the scx fetch filter in install_scx_from_release.
curl -fsSL "https://api.github.com/repos/${OWNER_REPO}/releases" | \
  jq '[.[] | select(.tag_name | startswith("scx-") | not)] | .[0]' > "$WORK_DIR/latest-release.json"

TAG="$(jq -r '.tag_name' "$WORK_DIR/latest-release.json")"

if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
  echo "error: no release tag found"
  exit 1
fi

# upstream kernel version extracted from tag: v7.0.10-cachyos-... -> 7.0.10
TAG_KVER="$(echo "$TAG" | sed 's/^v//; s/-cachyos.*//')"
echo "latest release: $TAG ($TAG_KVER)"

LAST_TAG_FILE="$STATE_DIR/last-installed-tag"

CURRENT_KERNEL="$(uname -r)"
echo "running: $CURRENT_KERNEL"

NEED_REBOOT_ONLY=0

if [ -f "$LAST_TAG_FILE" ] && [ "$(cat "$LAST_TAG_FILE")" = "$TAG" ]; then
  echo "$TAG already recorded as installed"

  if echo "$CURRENT_KERNEL" | grep -q 'cachyos.*nuc16pro'; then
    echo "already running custom kernel, re-applying tuning and checking SCX"
    NEED_REBOOT_ONLY=2
  elif dpkg -l | grep -qE '^ii[[:space:]]+linux-image-.*cachyos.*nuc16pro'; then
    echo "custom kernel installed but not running, will set GRUB default and reboot"
    NEED_REBOOT_ONLY=1
  fi
fi

# Verify the specific kernel version from this tag is actually present.
# The state file can lie if the package was never installed or was purged.
if [ "$NEED_REBOOT_ONLY" -ne 0 ]; then
  if ! dpkg -l 2>/dev/null | grep -qE "^ii[[:space:]]+linux-image-${TAG_KVER}" && \
     ! ls /boot/vmlinuz-"${TAG_KVER}"* 2>/dev/null | grep -q .; then
    echo "warn: state file says $TAG installed but kernel ${TAG_KVER} not found in dpkg/boot, reinstalling"
    NEED_REBOOT_ONLY=0
  fi
fi

if [ "$NEED_REBOOT_ONLY" -eq 0 ]; then
  msg "downloading release assets"
  rm -rf "$WORK_DIR/assets"
  mkdir -p "$WORK_DIR/assets"

  jq -r '.assets[] | select(.name | test("^(linux-(image|headers).*\\.deb|linux-libc-dev_.*\\.deb|SHA256SUMS|BUILD_MANIFEST)$")) | .browser_download_url' \
    "$WORK_DIR/latest-release.json" > "$WORK_DIR/urls.txt"

  cat "$WORK_DIR/urls.txt"

  grep -q 'linux-image'   "$WORK_DIR/urls.txt" || { echo "error: no linux-image asset";   exit 1; }
  grep -q 'linux-headers' "$WORK_DIR/urls.txt" || { echo "error: no linux-headers asset"; exit 1; }
  grep -q 'SHA256SUMS'    "$WORK_DIR/urls.txt" || { echo "error: no SHA256SUMS asset";    exit 1; }

  cd "$WORK_DIR/assets"
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    echo "  -> $url"
    curl -fLJO "$url"
  done < "$WORK_DIR/urls.txt"

  ls -lh

  cat BUILD_MANIFEST 2>/dev/null || true

  msg "verifying checksums"
  sha256sum -c SHA256SUMS

  msg "verifying package architecture"
  for deb in *.deb; do
    ARCH="$(dpkg --info "$deb" | awk '/Architecture:/ {print $2}')"
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "all" ]; then
      echo "error: unexpected architecture for $deb: $ARCH"
      exit 1
    fi
    dpkg --info "$deb" | grep -E 'Package:|Version:|Architecture:'
  done

  msg "installing fallback kernel"
  apt-get install -y linux-image-generic linux-headers-generic || true

  msg "installing kernel packages"
  mapfile -t DEBS < <(
    find . -maxdepth 1 -type f \
      \( -name 'linux-headers-*.deb' -o -name 'linux-image-*.deb' -o -name 'linux-libc-dev_*.deb' \) |
      sort
  )

  if [ "${#DEBS[@]}" -eq 0 ]; then
    echo "error: no .deb kernel packages found"; exit 1
  fi

  dpkg -i "${DEBS[@]}"
  apt-get -f install -y
fi

msg "system tuning"

BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/default/grub "$BACKUP_DIR/grub.bak" 2>/dev/null || true

# Intel Xe3 LP (Panther Lake iGPU, device 0xB0A0): xe driver, no i915 options needed
# xe driver auto-enables GuC firmware submission; no modprobe options required
install -Dm644 /dev/stdin /etc/modprobe.d/xe-nuc16pro.conf <<'MODPROBE'
# Intel Xe3 LP (Panther Lake, device 0xB0A0): xe driver
# GuC firmware submission is enabled by default in xe; no options needed.
# i915 is kept as fallback module but Panther Lake iGPU will bind to xe at boot.
MODPROBE

# Intel Wi-Fi 7 BE211: disable power save for max throughput on AC
install -Dm644 /dev/stdin /etc/modprobe.d/nuc16pro-wifi.conf <<'MODPROBE_WIFI'
options iwlwifi power_save=0
options iwlmvm power_scheme=1
MODPROBE_WIFI

# server sysctl tuning
install -Dm644 /dev/stdin /etc/sysctl.d/99-nuc16pro-servermax.conf <<'SYSCTL'
# TCP: BBR + FQ
net.core.default_qdisc             = fq
net.ipv4.tcp_congestion_control    = bbr
net.ipv4.tcp_fastopen              = 3

# large socket buffers (Plex, LAN transfers, Docker)
net.core.rmem_max                  = 134217728
net.core.wmem_max                  = 134217728
net.ipv4.tcp_rmem                  = 4096 87380 134217728
net.ipv4.tcp_wmem                  = 4096 65536 134217728

# inotify limits for Docker/containers
fs.inotify.max_user_watches        = 1048576
fs.inotify.max_user_instances      = 1024

# server memory bias
vm.swappiness                      = 10
vm.vfs_cache_pressure              = 50
vm.dirty_background_ratio          = 5
vm.dirty_ratio                     = 20

# high-load limits
fs.file-max                        = 2097152
net.core.netdev_max_backlog        = 16384

# Dual NIC: loose reverse-path filter allows multi-homed WiFi+ETH simultaneously.
# rp_filter=2 (loose) instead of 1 (strict) so both NICs can receive traffic
# when routing via the other interface (e.g. default via eth, DNS via wifi).
# NOT setting ip_forward: this is a workstation, not a router.
net.ipv4.conf.all.rp_filter        = 2
net.ipv4.conf.default.rp_filter    = 2

# NVMe: disable power-saving latency states for Gen4/Gen5 max throughput
# (mirrors kernel cmdline nvme_core.default_ps_max_latency_us=0)
# This is belt-and-suspenders; cmdline takes effect earlier at boot.
# dev.nvme is not a sysctl namespace; NVMe PS is controlled via cmdline only.
SYSCTL

# I/O scheduler: ADIOS for SSDs/NVMe, BFQ for spinning disks
install -Dm644 /dev/stdin /etc/udev/rules.d/60-nuc16pro-ioschedulers.rules <<'UDEV'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"
UDEV

# adios is built as a module (CONFIG_MQ_IOSCHED_ADIOS=m) and, unlike bfq, its module has no
# "<name>-iosched" autoload alias, so the udev rule's ATTR{queue/scheduler}="adios" write
# silently no-ops when adios is not already loaded (SSD/NVMe then fall back to mq-deadline or
# none). Load it explicitly at boot so it is registered before udev coldplug applies the rule.
install -Dm644 /dev/stdin /etc/modules-load.d/nuc16pro-adios.conf <<'MODLOAD'
# adios I/O scheduler (CONFIG_MQ_IOSCHED_ADIOS=m). Its module lacks the "<name>-iosched"
# autoload alias that bfq has, so writing "adios" to queue/scheduler from the udev rule
# (60-nuc16pro-ioschedulers.rules) no-ops unless adios is already loaded - SSD/NVMe then
# fall back to mq-deadline/none. Load it here so the rule can actually apply it at boot.
adios
MODLOAD

# power-profiles-daemon owns scaling_governor/EPP on intel_pstate and starts after
# our oneshot at boot, overriding it (a boot-time race). Mask it so the cpupower
# service below is the single, deterministic owner of EPP. This drops the GNOME
# power-profile toggle, which is fine on a performance server (EPP=performance fixed).
systemctl mask --now power-profiles-daemon.service 2>/dev/null || true

# CPU performance policy (EPP=performance) via systemd oneshot
# Panther Lake: 4P + 8E + 4LP-E = 16C/16T, no HT
# All CPU* loops cover P/E/LP-E uniformly; Intel Thread Director + HFI
# handles per-core-type scheduling automatically at the firmware level.
install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-servermax-cpupower.service <<'SERVICE'
[Unit]
Description=NUC 16 Pro ServerMax CPU performance policy (EPP + HWP boost + platform_profile, Panther Lake P/E/LP-E)
# Was After=multi-user.target, which measured as a real bug on this box: multi-user.target
# only became active at 42.8s into boot (it waits on the slowest thing in the graph, here
# crowdsec-firewall-bouncer at ~10.6s of its own start time), while docker.service started at
# 19.5s. So ~70 containers spent the first 23 seconds of their life running under the
# firmware's cold-boot power policy - platform_profile=balanced, EPP=balance_performance,
# hwp_dynamic_boost=0 - which is exactly the window where the container storm needs turbo the
# most. Same anti-pattern that used to delay the sched_ext attach until mid-storm.
# basic.target is late enough that cpufreq/intel_pstate sysfs is fully populated and early
# enough to beat docker.service (which waits on network-online.target). No cycle: nothing
# pulled in by basic.target wants docker.
After=basic.target
Before=docker.service

[Service]
Type=oneshot
# intel_pstate active mode. The powersave governor is the right default on this
# power-limited package (firmware clamps PL1 low under load): light cores drop
# frequency and release budget so loaded cores turbo higher. We do NOT pin the
# performance governor; it would hold idle cores at max P-state and steal that budget.
# Three knobs are asserted instead:
#  - EPP=performance: bias every core toward max under load.
#  - hwp_dynamic_boost=1: ramp frequency faster on task wakeup (lower latency).
#  - platform_profile=performance: firmware DPTF power slider to max. The cold-boot
#    firmware default here is balanced, and PPD (which used to assert this) is masked,
#    so nothing else sets it.
# power-profiles-daemon is masked by the updater, so this oneshot is the single owner
# of EPP / platform_profile (no boot-time race over those knobs).
ExecStart=/bin/sh -c 'for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do [ -w "$e" ] && echo performance > "$e" || true; done'
ExecStart=/bin/sh -c '[ -w /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost ] && echo 1 > /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost || true'
ExecStart=/bin/sh -c '[ -w /sys/firmware/acpi/platform_profile ] && echo performance > /sys/firmware/acpi/platform_profile || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable nuc16pro-servermax-cpupower.service || true
# restart, not just enable: RemainAfterExit=yes means an already-active oneshot
# won't re-run ExecStart just because the unit file changed underneath it
systemctl restart nuc16pro-servermax-cpupower.service || true

# Runtime device tuning within the BIOS power envelope: energy_perf_bias, NVMe queue depth, igc rings, TjMax passive trip (BIOS owns PL1/PL2/Tau, platform_profile, and fan curves)
install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-servermax-power.service <<'POWER_SVC'
[Unit]
Description=NUC 16 Pro ServerMax device tuning (BIOS owns power limits and fan curves)
# Moved off After=multi-user.target for the same measured reason as the cpupower unit: that
# target only went active at 42.8s while docker.service started at 19.5s, so the NVMe queue
# depth, NIC ring sizes and thermal trip points were all still at their defaults while the
# container fleet was starting. See the cpupower unit for the full timing breakdown.
# The devices this unit touches (block queues, igc NICs, thermal zones) are all created by
# udev during sysinit, well before basic.target, so nothing here races an absent sysfs path.
After=basic.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
# msr: lets turbostat read per-core MHz / package watts for diagnostics. Non-fatal.
# (Uncore/mesh frequency pinning was evaluated and dropped: this Panther Lake mobile SoC
# exposes intel_uncore_frequency sysfs but ignores min_freq_khz writes - HWP owns uncore
# scaling here - so a pin is inert. HWP already ramps uncore under load.)
ExecStartPre=-/sbin/modprobe msr
# Power limits (PL1/PL2/Tau) are deliberately NOT written here. The 356H is hard-capped
# at its 80W Maximum Turbo Power (Intel spec), confirmed on-device (package stays <=80W
# under stress even with RAPL raised to 104W). A write above 80W is inert and below it
# would only throttle, so there is nothing to gain; BIOS owns PL1/PL2/Tau, and the
# updater still reads the RAPL constraints for status so they stay visible. (The ACPI
# platform_profile IS set to performance, but by the cpupower service, not here.)
# Everything below tunes devices WITHIN the BIOS envelope and never changes power
# limits or fan curves.
# energy_perf_bias=0: no microarchitecture power-saving bias on any core
ExecStart=/bin/sh -c 'for b in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do [ -w "$b" ] && printf 0 > "$b"; done; true'
# NVMe: maximize request queue depth per namespace for Gen4/Gen5 throughput
ExecStart=/bin/sh -c 'for q in /sys/block/nvme*/queue/nr_requests; do [ -w "$q" ] && printf 1023 > "$q"; done; true'
# igc (dual I226-V 2.5GbE): maximize ring buffers on EVERY igc NIC. The box has two
# (enp86s0 + enp87s0, both UP); the old grep -m1 "^e" tuned only the first. Match by driver
# so docker bridges/veths are skipped and only real igc ports are touched.
ExecStart=/bin/sh -c 'for n in /sys/class/net/*; do [ -e "$n/device/driver" ] || continue; [ "$(basename "$(readlink "$n/device/driver")")" = igc ] || continue; ethtool -G "$(basename "$n")" rx 4096 tx 4096 2>/dev/null || true; done; true'
# Thermal: set x86 package passive trip point to 100C = TjMax for Panther Lake 356H.
# This lets the CPU run at full turbo until hardware PROCHOT fires at TjMax.
# Only type=passive trips are touched; type=critical (emergency shutdown) is left untouched.
# Millidegrees: 100000. Writable unconditionally in kernel 6.14+ (no CONFIG_THERMAL_WRITABLE_TRIPS needed).
# NOTE: the loop index is written $${i} so systemd emits a literal ${i} to the shell.
# An unescaped ${i} is expanded by systemd itself to an empty string (journal warns
# "unset environment variable ... i"), which silently breaks the trip-setting loop.
ExecStart=/bin/sh -c 'for zone in /sys/class/thermal/thermal_zone*; do ztype=$(cat "$zone/type" 2>/dev/null || true); [ "$ztype" = "x86_pkg_temp" ] || continue; for i in 0 1; do ttype=$(cat "$zone/trip_point_$${i}_type" 2>/dev/null || true); ttemp="$zone/trip_point_$${i}_temp"; [ "$ttype" = "passive" ] || continue; [ -w "$ttemp" ] && printf 100000 > "$ttemp" 2>/dev/null && echo "thermal: $ttemp=100000" || true; done; done; true'

[Install]
WantedBy=multi-user.target
POWER_SVC

systemctl daemon-reload
systemctl enable nuc16pro-servermax-power.service || true
# restart, not just enable: RemainAfterExit=yes means an already-active oneshot
# won't re-run ExecStart just because the unit file changed underneath it.
# This is what actually pushes a wattage/Tau change live on a machine that's
# already on the target kernel (no kernel change -> no reboot -> service never re-fires).
systemctl restart nuc16pro-servermax-power.service || true

# Memory policy: multi-size THP mid orders, DAMON proactive reclaim, KSM asserted off.
# Measured motivation (see the unit for the numbers): with only the 2MB PMD order enabled,
# 81% of THP faults on this box fell back to 4K pages because a 30GB machine running ~70
# containers is too fragmented to serve 2MB contiguous allocations. Enabling 16k/32k/64k
# gave the fault path somewhere to land and produced ~700k successful huge-page allocations
# in ~10 minutes, 64k succeeding 87.6% of the time.
install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-servermax-mm.service <<'MM_SVC'
[Unit]
Description=NUC 16 Pro ServerMax memory tuning (multi-size THP orders + DAMON proactive reclaim)
# Ordered like the scx_loader drop-in, NOT After=multi-user.target. The mm policy has to be
# in place before dockerd forks the container fleet, otherwise ~70 containers fault in their
# anonymous memory under the old policy and only inherit the new one for later allocations.
# basic.target is late enough that /sys/kernel/mm is fully populated and the damon_reclaim
# module parameters exist, and early enough to land ahead of docker.service (which waits on
# network-online.target). No ordering cycle: nothing in basic.target wants docker.
After=basic.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes

# --- multi-size THP (mTHP) ---------------------------------------------------------------
# Measured on this box: with only the PMD (2MB) order enabled, 81% of THP faults FELL BACK to
# 4K pages (thp_fault_alloc 172801 vs thp_fault_fallback 1573192) because 30GB of RAM running
# ~70 containers plus a 14GB page cache is far too fragmented to hand out 2MB contiguous
# blocks on demand. The kernel defaults every non-PMD order to "never"
# (Documentation/admin-guide/mm/transhuge.rst: "By default, PMD-sized hugepages have
# enabled=inherit and all other hugepage sizes have enabled=never"), so those faults had no
# middle ground to land on.
#
# Enabling the mid orders gives the fault path somewhere to go before it gives up on huge
# pages entirely. Re-measured on this box ~10 minutes after enabling:
#   64kB  alloc 363443 / fallback  51554  = 87.6% success
#   16kB  alloc 215758 / fallback  85548  = 71.6% success
#   32kB  alloc 123649 / fallback  70767  = 63.6% success
#   2048kB (PMD, unchanged) alloc 36299 / fallback 152647 = 19.2% success
# ~700k huge-page allocations succeeded that would previously have been 4K pages. Fewer,
# larger mappings mean fewer page faults and less TLB pressure for the same working set.
#
# Only 16k/32k/64k are enabled. 128k-1024k are left at "never" on purpose: they are rarely
# a natural fit for allocation sizes, and every extra enabled order adds internal
# fragmentation and another rung for the allocator to try and fail on. The PMD order keeps
# "inherit" so it continues to follow the global enabled=always.
ExecStart=/bin/sh -c 'for o in 16 32 64; do e=/sys/kernel/mm/transparent_hugepage/hugepages-$${o}kB/enabled; [ -w "$e" ] && echo always > "$e" || true; done; true'
# Let the kernel reclaim THPs that are mostly zero-filled instead of pinning the memory.
# Matters more once the mid orders are live, since there are simply more THPs around.
ExecStart=/bin/sh -c '[ -w /sys/kernel/mm/transparent_hugepage/shrink_underused ] && echo 1 > /sys/kernel/mm/transparent_hugepage/shrink_underused || true'

# --- KSM: deliberately OFF ---------------------------------------------------------------
# Tested on this box, not assumed. KSM was enabled with advisor_mode=scan-time and left to
# run: after 436 full scans and 1.6M pages scanned it had merged FIFTEEN pages, and
# general_profit read -1884032, i.e. KSM's own metadata cost ~1.8MB MORE than it saved.
# Reason: KSM only ever looks at memory a process has opted in via madvise(MADV_MERGEABLE)
# or prctl(PR_SET_MEMORY_MERGE), and Docker/containerd do neither. Containers already share
# their read-only image layers through the overlayfs page cache, which is where the real
# duplication would have been. So KSM has nothing to merge here and is pure scan overhead.
# Asserted off rather than left at the default so a future distro/kernel default flip cannot
# quietly re-enable a known-negative feature. Re-test with general_profit if the container
# runtime ever starts setting PR_SET_MEMORY_MERGE.
ExecStart=/bin/sh -c '[ -w /sys/kernel/mm/ksm/run ] && echo 0 > /sys/kernel/mm/ksm/run || true'

# --- DAMON proactive reclaim: TRIED, MEASURED, DROPPED -----------------------------------
# DAMON_RECLAIM was enabled here for ~19 hours with min_age=60s, quota_sz=128MiB/s,
# quota_ms=10 and always-on watermarks (high=1000 mid=1000 low=0, because this box runs at
# ~1.5% free with most of RAM as page cache, so the documented example wmarks_low=200 would
# have parked it below its own low watermark and it would never have run at all).
#
# Result: bytes_reclaimed_regions=0, nr_reclaimed_regions=0, while nr_quota_exceeds=2 proved
# the kdamond was alive and actually hitting its quota, and the box was still sitting on
# 6.6GB of swap with 2.09M zswap writeouts this boot. So it ran, it cost CPU, and it
# reclaimed nothing measurable. The reason is that there is no idle cold anonymous memory to
# find: MGLRU (fully enabled, 0x0007) plus the zswap shrinker are already draining cold
# anon continuously, so by the time a page is 60s idle it has usually been dealt with.
# DAMON is aimed at workloads where reclaim is bursty and latency-sensitive; a media server
# that swaps steadily is not that shape.
#
# Left OFF rather than tuned down further: a shorter min_age would just make it compete with
# MGLRU for the same pages. Asserted N so a leftover module parameter from an earlier boot
# cannot silently restart it. Reverting is one line if the workload ever changes shape.
ExecStart=-/bin/sh -c 'test -w /sys/module/damon_reclaim/parameters/enabled && echo N > /sys/module/damon_reclaim/parameters/enabled || true'

[Install]
WantedBy=multi-user.target
MM_SVC

systemctl daemon-reload
systemctl enable nuc16pro-servermax-mm.service || true
# restart for the same RemainAfterExit reason as the units above: an already-active oneshot
# will not re-run ExecStart just because the unit file changed on disk.
systemctl restart nuc16pro-servermax-mm.service || true

# dm-crypt: bypass the internal read/write workqueues. dm-crypt defaults to queueing crypto
# work onto an unbound workqueue and, for writes, offloading again to a second thread; on a
# machine with AES-NI/VAES (this box exposes vaes and uses aes-xts-plain64, so xts(aes) runs
# in hardware) the crypto itself is far cheaper than that scheduling round-trip, and the
# queues just add latency and context switches. no-read-workqueue / no-write-workqueue make
# dm-crypt process requests synchronously instead (crypttab(5), kernel 5.9+, cryptsetup 2.2+).
# This matters here because the root LV and both data disks are all LUKS, so every container
# read and write pays the dm-crypt path.
#
# Auto-detected, never hardcoded: the loop rewrites whatever crypttab entries the box has, so
# no UUID or device name from this machine ends up in the repo. Idempotent (skips lines that
# already carry the flags) and backs up once before the first edit. Applied live with
# `cryptsetup refresh` where a keyfile is available, which reloads the dm table without
# unmounting; entries that unlock from the TPM or a passphrase (typically root) just pick the
# flags up on the next boot. The crypttab edit is what makes it durable, so initramfs is
# regenerated when the root device's entry changes.
if [ -f /etc/crypttab ] && command -v cryptsetup >/dev/null 2>&1; then
  CRYPTTAB_CHANGED=0
  cp -n /etc/crypttab /etc/crypttab.nuc16pro-servermax.bak 2>/dev/null || true
  while read -r CT_NAME CT_DEV CT_KEY CT_OPTS; do
    case "$CT_NAME" in ''|\#*) continue ;; esac
    [ -n "$CT_OPTS" ] || continue
    case "$CT_OPTS" in *no-read-workqueue*) continue ;; esac
    sed -i "s|^\([[:space:]]*$CT_NAME[[:space:]].*\)\$|\1,no-read-workqueue,no-write-workqueue|" /etc/crypttab
    CRYPTTAB_CHANGED=1
    # Live-apply where we can unlock non-interactively; harmless if it fails.
    if [ -n "$CT_KEY" ] && [ "$CT_KEY" != "none" ] && [ -f "$CT_KEY" ]; then
      cryptsetup refresh --key-file "$CT_KEY" \
        --perf-no_read_workqueue --perf-no_write_workqueue "$CT_NAME" 2>/dev/null \
        && echo "dm-crypt: $CT_NAME refreshed live with no_read/no_write_workqueue" \
        || echo "dm-crypt: $CT_NAME will pick up the flags on next boot"
    else
      echo "dm-crypt: $CT_NAME unlocks without a keyfile, flags apply on next boot"
    fi
  done < /etc/crypttab
  if [ "$CRYPTTAB_CHANGED" = 1 ]; then
    # Root's crypttab entry is consumed from the initramfs, so it has to be rebuilt.
    command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u >/dev/null 2>&1 || true
  fi
fi

# Docker log rotation. The daemon defaults to json-file with NO size limit, so a chatty
# container can grow a single log file until the filesystem fills - on a box with ~70 of them
# that is a real availability risk, and the writes land on the LUKS root LV. 50MB x 3
# compressed caps total log usage at a bounded figure per container. Merged into any existing
# daemon.json rather than overwriting it, because this box legitimately sets "dns" there.
# Deliberately NOT restarting dockerd: that would bounce every container. The new limits
# apply to containers as they are next recreated, and unconditionally after the next reboot.
# live-restore is set at the same time so a future dockerd restart leaves containers running.
if [ -d /etc/docker ] && command -v python3 >/dev/null 2>&1; then
  cp -n /etc/docker/daemon.json /etc/docker/daemon.json.nuc16pro-servermax.bak 2>/dev/null || true
  python3 - <<'DOCKER_JSON' || echo "docker: daemon.json untouched (parse failure, left as-is)"
import json, os
p = "/etc/docker/daemon.json"
try:
    d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
except Exception:
    raise SystemExit(1)
if not isinstance(d, dict):
    raise SystemExit(1)
d.setdefault("log-driver", "json-file")
opts = d.get("log-opts") if isinstance(d.get("log-opts"), dict) else {}
opts.update({"max-size": "50m", "max-file": "3", "compress": "true"})
d["log-opts"] = opts
d.setdefault("live-restore", True)
json.dump(d, open(p, "w"), indent=2)
DOCKER_JSON
fi

# bluetoothd on a headless server: it finds nearby devices it can never pair and logs a
# failure for each one. Measured on this box: 9436 of 10182 journal error lines in a single
# boot, 93% of the entire error log, which buries anything that actually matters and writes
# journal to the encrypted root for no reason. No BT peripherals are used on a rack box.
# Guarded so it is a no-op where bluetooth is not installed, and trivially reversible with
# `systemctl enable --now bluetooth`.
# Headless-server plymouth deadlock: plymouth-quit-wait.service runs `plymouth --wait` with
# TimeoutStartUSec=infinity and is ordered Before=multi-user.target. On a server with no
# graphical/display-manager handoff plymouthd never quits, so the unit blocks forever and
# multi-user.target never completes - starving every After=multi-user.target unit (the
# servermax tuning oneshots above) and leaving no getty console fallback. A drop-in replaces
# ExecStart with /usr/bin/true so the oneshot succeeds instantly: nothing that Wants it
# breaks, the target completes, tuning fires, and plymouth-quit.service tears down plymouthd
# normally. Reversible (rm the drop-in), no GRUB/cmdline change. Guarded so it is a no-op on
# systems without plymouth.
if systemctl cat plymouth-quit-wait.service >/dev/null 2>&1; then
  install -Dm644 /dev/stdin /etc/systemd/system/plymouth-quit-wait.service.d/10-headless-noop.conf <<'PLY_NOOP'
# Headless server: plymouthd never gets a graphical/display-manager handoff, so the stock
# ExecStart `plymouth --wait` blocks with TimeoutStartUSec=infinity. plymouth-quit-wait is
# ordered Before=multi-user.target, so the whole target stalls and every
# After=multi-user.target unit (the servermax tuning oneshots) plus the getty console never
# start. Replace the wait with a no-op: the oneshot still runs and succeeds instantly, so
# nothing that Wants it breaks, the target completes, and plymouth-quit.service then tears
# down plymouthd normally.
[Service]
ExecStart=
ExecStart=/usr/bin/true
PLY_NOOP
  systemctl daemon-reload
fi

msg "installing sched_ext schedulers"

LAST_SCX_TAG_FILE="$STATE_DIR/last-installed-scx-tag"

install_scx_from_release() {
  echo "checking latest scx-* release..."

  local scx_work="$WORK_DIR/scx-assets"
  local scx_json="$WORK_DIR/latest-scx-release.json"

  # Same repo as the kernel releases; filter to the scx-* tag stream since
  # /releases/latest would resolve to whichever stream published most recently.
  curl -fsSL "https://api.github.com/repos/${OWNER_REPO}/releases" | \
    jq '[.[] | select(.tag_name | startswith("scx-"))] | .[0]' > "$scx_json"

  local scx_tag
  scx_tag="$(jq -r '.tag_name' "$scx_json")"

  if [ -z "$scx_tag" ] || [ "$scx_tag" = "null" ]; then
    echo "warn: no scx-* release found in ${OWNER_REPO}"
    return 1
  fi

  if [ -f "$LAST_SCX_TAG_FILE" ] && [ "$(cat "$LAST_SCX_TAG_FILE")" = "$scx_tag" ]; then
    echo "scx $scx_tag already installed, skipping"
    return 0
  fi

  echo "installing scx schedulers: $scx_tag"

  rm -rf "$scx_work"
  mkdir -p "$scx_work"

  jq -r '.assets[] | select(.name | test("^(scx_flash|scx_bpfland|scx_p2dq|scx_rusty|scx_beerland|scx_lavd|scx_loader|scxctl|scx_loader[.]service|org[.]scx[.]Loader[.]service|org[.]scx[.]Loader[.]conf|org[.]scx[.]Loader[.]policy|SHA256SUMS|BUILD_MANIFEST)$")) | .browser_download_url' \
    "$scx_json" > "$scx_work/urls.txt"

  grep -q 'SHA256SUMS' "$scx_work/urls.txt" || { echo "error: no SHA256SUMS asset in $scx_tag"; return 1; }

  (
    cd "$scx_work"
    while IFS= read -r url; do
      [ -z "$url" ] && continue
      echo "  -> $url"
      curl -fLJO "$url"
    done < urls.txt

    ls -lh
    cat BUILD_MANIFEST 2>/dev/null || true

    sha256sum -c SHA256SUMS

    for b in scx_flash scx_bpfland scx_p2dq scx_rusty scx_beerland scx_lavd; do
      [ -f "$b" ] || { echo "error: $b missing from $scx_tag assets"; exit 1; }
      install -Dm755 "$b" "/usr/local/bin/$b"
    done
    # scx_loader (DBus scheduler loader) + scxctl (CLI) + their systemd/DBus/polkit files.
    # Guarded so older scx-* releases without them still install cleanly.
    if [ -f scx_loader ] && [ -f scxctl ]; then
      install -Dm755 scx_loader "/usr/local/bin/scx_loader"
      install -Dm755 scxctl     "/usr/local/bin/scxctl"
      [ -f scx_loader.service ]     && install -Dm644 scx_loader.service     /etc/systemd/system/scx_loader.service
      [ -f org.scx.Loader.service ] && install -Dm644 org.scx.Loader.service /usr/share/dbus-1/system-services/org.scx.Loader.service
      [ -f org.scx.Loader.conf ]    && install -Dm644 org.scx.Loader.conf    /usr/share/dbus-1/system.d/org.scx.Loader.conf
      [ -f org.scx.Loader.policy ]  && install -Dm644 org.scx.Loader.policy  /usr/share/polkit-1/actions/org.scx.Loader.policy
      # Boot-order drop-in: attach scx_flash before the docker container storm (the
      # guarantee the direct nuc16pro-scx-server.service carried). Kept as a .d/
      # override because the line above overwrites the upstream unit each run.
      install -Dm644 /dev/stdin /etc/systemd/system/scx_loader.service.d/10-nuc16pro-boot-order.conf <<'SCX_ORDER'
# Drop-in for scx_loader.service (installed to
# /etc/systemd/system/scx_loader.service.d/10-nuc16pro-boot-order.conf).
#
# Kept separate from the upstream unit because the updater overwrites
# /etc/systemd/system/scx_loader.service from the scx-* release asset on every run;
# a drop-in survives that and systemd merges After=/Before= additively.
[Unit]
# Attach the sched_ext scheduler before dockerd launches the container fleet, the
# same guarantee the direct nuc16pro-scx-server.service carried before scx_loader
# took over. scx_loader is gated only on dbus.socket + basic.target, so it comes up
# ~6-7s into boot and attaches scx_flash ahead of docker.service, which waits on
# network-online.target (~13-14s in) before starting ~47 containers. Attaching
# pre-storm avoids the boot-time ops.cgroup_init() -ENOMEM that hit the old late
# (~68s, mid-storm) attach. SOFT order (scx_loader is Type=dbus, marked started at
# bus-name acquisition, not at scheduler-attach), but flash wins by margin in
# practice: measured flash 7.1s vs docker 13.7s on this box.
After=basic.target
Before=docker.service

[Service]
# Upstream ships Restart=no. Bring the loader back if the daemon dies so the box
# never sits with no control plane, matching the direct unit's on-failure policy.
Restart=on-failure
RestartSec=10
SCX_ORDER
      echo "installed scx_loader + scxctl control plane"
    fi
  ) || return 1

  echo "$scx_tag" > "$LAST_SCX_TAG_FILE"
  SCX_UPDATED=1
}

SCX_UPDATED=0
install_scx_from_release || echo "warn: scx install/update failed, existing binaries (if any) kept"

msg "scx binaries"
for b in scx_flash scx_bpfland scx_p2dq scx_rusty scx_beerland scx_lavd scx_loader scxctl; do
  if command -v "$b" >/dev/null 2>&1; then
    echo "  found:   $b -> $(command -v "$b")"
  else
    echo "  missing: $b"
  fi
done

msg "configuring sched_ext server mode"
# Primary: scx_flash (EDF + dynamic latency weights - prioritizes latency-sensitive
#   tasks that yield early, deprioritizes batch tasks that burn their full slice; well
#   matched to Plex transcode running alongside interactive streaming + networking).
#   Falls through to scx_bpfland -s 20000 -S (proven) if flash is absent OR fails to
#   attach, then p2dq -> bpfland(no args) -> rusty -> beerland -> lavd.
#
# scx_lavd is topology-aware for Panther Lake P/E/LP-E but has a documented E-core
# over-prioritization issue (observed on Lunar Lake, sibling arch), so it stays last.
#
# Unlike a plain exec chain, this VERIFIES each scheduler actually attaches to
# sched_ext before committing to it. A primary that dies or never attaches degrades
# to the proven fallback, never to "no scheduler".

install -Dm755 /dev/stdin /usr/local/sbin/scx-servermax-start.sh <<'SCX_WRAPPER'
#!/bin/sh
set -u

OPS=/sys/kernel/sched_ext/root/ops

# sched_ext attaches exactly one scheduler at a time, and root/ops exists only
# while one is attached (the whole root/ dir is absent when none is - verified on
# this kernel). We launch exactly one scheduler, so a non-empty root/ops means it
# attached. Deliberately NOT matching the reported name: schedulers name themselves
# differently (bpfland_1.1.1_..., flash_..., etc.) and a wrong needle would kill a
# working scheduler every boot and silently fall back - the exact failure this guard
# exists to prevent.
attached() { [ -n "$(cat "$OPS" 2>/dev/null)" ]; }

try() {
  s="$1"; a="$2"
  command -v "$s" >/dev/null 2>&1 || return 1
  echo "starting $s $a"
  # word-splitting $a into args is intentional
  "$s" $a &
  pid=$!
  trap 'kill "$pid" 2>/dev/null' TERM INT
  n=0
  while [ "$n" -lt 12 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "$s exited during startup"; wait "$pid" 2>/dev/null; trap - TERM INT; return 1
    fi
    if attached; then
      echo "$s attached"
      wait "$pid"        # stay foregrounded so systemd tracks the running scheduler
      exit $?
    fi
    n=$((n + 1)); sleep 1
  done
  echo "$s did not attach within 12s, trying next"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; trap - TERM INT
  return 1
}

# The primary (scx_flash) can transiently fail ops.cgroup_init() with -ENOMEM during
# the boot container storm: ~20 docker-compose services mass-launch and extract images
# in parallel and the kernel briefly cannot satisfy the scheduler's cgroup BPF
# allocation (measured on this box: the scheduler unit starts ~68s into boot while
# image work runs past ~2.5min). flash attaches cleanly once the storm eases, so retry
# the primary on a backed-off window before demoting to the proven fallback. try()
# exits the script on attach, so this loop only returns on failure; while it retries
# the kernel's own EEVDF scheduler runs (the box stays scheduled, just not yet on the
# custom scheduler). Tradeoff: if flash never attaches, the bpfland floor lands one
# full retry window later (~135s) than the old single-attempt chain, so a boot where
# every retry fails is mildly worse than before (longer EEVDF), not neutral; a boot
# where a retry catches runs flash for the whole session.
try_primary() {
  command -v scx_flash >/dev/null 2>&1 || return 1
  i=1
  while [ "$i" -le 8 ]; do
    try scx_flash ""
    [ "$i" -eq 8 ] && break
    d=$((i * 5)); [ "$d" -gt 30 ] && d=30
    echo "scx_flash attempt $i did not attach; retrying in ${d}s (boot memory pressure?)"
    sleep "$d"
    i=$((i + 1))
  done
  echo "scx_flash did not attach after 8 attempts, falling back to proven chain"
  return 1
}

try_primary                       || \
try scx_bpfland  "-s 20000 -S"    || \
try scx_p2dq     "--keep-running" || \
try scx_bpfland  ""               || \
try scx_rusty    ""               || \
try scx_beerland ""               || \
try scx_lavd     ""               || \
{ echo "no scx scheduler attached, kernel EEVDF remains active"; exit 0; }
SCX_WRAPPER

install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-scx-server.service <<'SCX_SVC'
[Unit]
Description=sched_ext server scheduler - ASUS NUC 16 Pro (Panther Lake)
Documentation=https://github.com/sched-ext/scx
# Attach the scheduler before dockerd starts the container fleet. sched_ext runs
# ops.cgroup_init() once per existing cgroup at attach time; attaching after the
# ~20 docker-<app>.service units launch means ~175 cgroups are initialized in one
# batch under boot slab pressure, which transiently fails -ENOMEM (cgroup_init -12)
# and demotes the scheduler to the fallback. Attaching before docker.service inits
# only a handful of cgroups up front, then each container's cgroup is initialized
# incrementally as it starts. After=basic.target keeps /usr/local/bin and the cgroup
# hierarchy ready; Before=docker.service makes scx's ExecStart fire before dockerd's. This is
# a SOFT order, not a hard gate: Type=simple marks the unit started at fork, so docker is not
# held until flash has attached - in practice flash wins because docker also waits on
# network-online.target (~13-14s in) while flash attaches in ~1s (a few s more if attempt 1
# hits the early-boot ENOMEM and retries), and the try_primary retry below covers any miss.
# (Was After=multi-user.target, which fired the unit ~68s in, mid-storm, behind a
# plymouth-gated target, and left a queued-but-unrun start job.)
After=basic.target
Before=docker.service
ConditionPathIsDirectory=/sys/kernel/sched_ext

[Service]
Type=simple
Restart=on-failure
RestartSec=10
ExecStart=/usr/local/sbin/scx-servermax-start.sh

[Install]
WantedBy=multi-user.target
SCX_SVC

# prefer scx_loader when available (handles kernel upgrades without service restart)
systemctl daemon-reload
if systemctl cat scx_loader.service >/dev/null 2>&1; then
  mkdir -p /etc/scx_loader
  cat > /etc/scx_loader/config.toml <<'SCX_CFG'
default_sched = "scx_flash"
default_mode  = "Server"
SCX_CFG
  systemctl reload dbus 2>/dev/null || true   # apply org.scx.Loader.conf policy (reload, not restart)
  systemctl daemon-reload
  # Release sched_ext from the direct service before scx_loader attaches (only one
  # scheduler can attach at a time), then hand over. If scx_loader fails to come up,
  # fall back to the direct service so the box never lands on no scheduler.
  systemctl stop nuc16pro-scx-server.service 2>/dev/null || true
  if systemctl enable --now scx_loader.service && systemctl is-active --quiet scx_loader.service; then
    systemctl disable nuc16pro-scx-server.service 2>/dev/null || true
    echo "scx_loader active (scxctl available)"
  else
    echo "warn: scx_loader.service failed to start; reverting to direct scx service"
    systemctl enable --now nuc16pro-scx-server.service || true
  fi
else
  systemctl enable --now nuc16pro-scx-server.service || true
fi

if [ "$NEED_REBOOT_ONLY" -eq 2 ]; then
  SCX_ACTIVE=0
  systemctl is-active --quiet nuc16pro-scx-server.service 2>/dev/null && SCX_ACTIVE=1 || true
  systemctl is-active --quiet scx_loader.service          2>/dev/null && SCX_ACTIVE=1 || true
  # enable --now above is a no-op if the unit is already running, so a same-day
  # scx binary update would otherwise sit on disk unused until the next
  # kernel-driven reboot (weeks out). Restart whenever a new tag just landed,
  # not just when nothing is running at all.
  if [ "$SCX_ACTIVE" -eq 0 ] || [ "$SCX_UPDATED" -eq 1 ]; then
    echo "SCX not active or just updated, (re)starting..."
    systemctl restart nuc16pro-scx-server.service 2>/dev/null || \
      systemctl restart scx_loader.service 2>/dev/null || true
  else
    echo "SCX active, no update"
  fi
fi

msg "installing post-boot health-check"
# Read-only status report (kernel, failed units, scx attach + cgroup_init count, xe/firmware,
# VA-API, bond, memory, thermal, NVMe SMART, docker health) run ~5 min post-boot and daily by a
# timer; output lands in the journal (journalctl -u nuc16pro-healthcheck). Recommended by the
# Panther Lake validation report. Never changes state.
install -Dm755 /dev/stdin /usr/local/sbin/nuc16pro-healthcheck <<'HEALTHCHECK'
#!/usr/bin/env bash
# ASUS NUC 16 Pro ServerMax - post-boot health report (read-only).
# Run by nuc16pro-healthcheck.timer (~5 min post-boot + daily); output goes to the journal:
#   journalctl -u nuc16pro-healthcheck.service
# Manual run: sudo nuc16pro-healthcheck
# Never changes system state. Always exits 0 (a report, not a gate); [WARN] lines flag anything off.
set -u

warn=0
note() { printf '  %s\n' "$*"; }
flag() { printf '  [WARN] %s\n' "$*"; warn=$((warn + 1)); }
sec()  { printf '[%s]\n' "$1"; }

echo "==== nuc16pro health $(date -u +%Y-%m-%dT%H:%M:%SZ) ===="

sec kernel
note "running: $(uname -r)"
case "$(uname -r)" in
  *cachyos*nuc16pro*servermax*) note "custom servermax kernel: yes" ;;
  *) flag "not running the custom servermax kernel" ;;
esac
note "uptime:$(uptime -p 2>/dev/null | sed 's/^up//' || true)"

sec systemd
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ -z "$failed" ]; then
  note "failed units: 0"
else
  flag "failed units: $(printf '%s\n' "$failed" | wc -l)"
  printf '%s\n' "$failed" | sed 's/^/         /'
fi

sec sched_ext
state=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo n/a)
ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || echo "")
note "state: $state   attached: ${ops:-<none>}"
if [ "$state" = enabled ] && [ -n "$ops" ]; then
  note "scheduler attached: ok"
else
  flag "no scx scheduler attached (kernel EEVDF is active)"
fi
nr=$(systemctl show nuc16pro-scx-server.service -p NRestarts --value 2>/dev/null || echo '?')
note "scx unit restarts this boot: $nr"
cg=$(journalctl -b -k 2>/dev/null | grep -ciE 'cgroup_init\(\) failed')
note "cgroup_init ENOMEM events this boot: $cg (boot-storm transient; absorbed by try_primary retry)"

sec gpu-xe
[ -d /sys/bus/pci/drivers/xe ] && note "xe driver bound: yes" || flag "xe driver not bound"
[ -e /dev/dri/renderD128 ] && note "render node: present" || flag "render node /dev/dri/renderD128 missing"
fw=$(journalctl -b -k 2>/dev/null | grep -oE 'GSC firmware from [^ ]+ version [0-9.]+' | tail -1)
[ -n "$fw" ] && note "$fw"
if journalctl -b -k 2>/dev/null | grep -q 'PXP requires PTL GSC build'; then
  note "PXP: unavailable (shipped GSC firmware below kernel's PXP minimum; VA-API transcode unaffected)"
fi

sec va-api
if [ -e /usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so ]; then
  note "host iHD driver: present"
  if command -v vainfo >/dev/null 2>&1; then
    p=$(vainfo 2>/dev/null | grep -c VAProfile)
    if [ "${p:-0}" -gt 0 ]; then note "vainfo profiles: $p"; else flag "vainfo returned no profiles"; fi
  fi
else
  flag "host iHD VA-API driver absent (host-side hardware transcode unavailable)"
fi

sec remote-desktop
if systemctl cat gnome-remote-desktop.service >/dev/null 2>&1; then
  note "gnome-remote-desktop: $(systemctl is-active gnome-remote-desktop.service 2>/dev/null)"
  # Xe3 workaround: RDP --handover daemon SIGSEGVs in the Intel Vulkan driver unless
  # pinned to software Vulkan (lavapipe). Flag if that pin ever disappears (regression).
  if grep -qs 'lvp_icd' /etc/environment /etc/systemd/system/gnome-remote-desktop.service.d/*.conf; then
    note "RDP software-Vulkan workaround: present"
  else
    flag "RDP software-Vulkan workaround missing (Xe3 RDP handover will SIGSEGV)"
  fi
  bt=$(date -d "$(uptime -s)" +%s 2>/dev/null || echo 0)
  nc=0
  for f in /var/crash/_usr_libexec_gnome-remote-desktop-daemon.*.crash; do
    [ -e "$f" ] || continue
    [ "$(stat -c %Y "$f" 2>/dev/null || echo 0)" -gt "$bt" ] && nc=$((nc + 1))
  done
  [ "$nc" -eq 0 ] && note "no RDP daemon crashes since boot" || flag "gnome-remote-desktop crashed $nc time(s) since boot"
else
  note "gnome-remote-desktop: not installed"
fi

sec network
if [ -d /sys/class/net/bond0 ]; then
  mode=$(cat /sys/class/net/bond0/bonding/mode 2>/dev/null)
  slaves=$(cat /sys/class/net/bond0/bonding/slaves 2>/dev/null)
  up=0; tot=0
  for s in $slaves; do
    tot=$((tot + 1))
    [ "$(cat /sys/class/net/"$s"/operstate 2>/dev/null)" = up ] && up=$((up + 1))
  done
  note "bond0: mode ${mode%% *}; slaves up: $up/$tot (${slaves:-none})"
  { [ "$tot" -gt 0 ] && [ "$up" -eq "$tot" ]; } || flag "bond0 has slaves down ($up/$tot up)"
else
  note "bond0: not configured"
fi

sec memory
free -h | awk '/^Mem:/{printf "  mem used %s / %s (avail %s)\n",$3,$2,$7} /^Swap:/{printf "  swap used %s / %s\n",$3,$2}'
oom=$(awk '/oom_kill/{print $2}' /proc/vmstat 2>/dev/null)
oom=${oom:-0}
if [ "$oom" -eq 0 ] 2>/dev/null; then note "oom kills since boot: $oom"; else flag "oom kills since boot: $oom"; fi

sec thermal
tt=0
for c in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
  [ -r "$c" ] && tt=$((tt + $(cat "$c" 2>/dev/null || echo 0)))
done
note "core throttle events (cumulative): $tt"

sec storage
if command -v nvme >/dev/null 2>&1; then
  for d in /dev/nvme[0-9]n[0-9]; do
    [ -e "$d" ] || continue
    s=$(nvme smart-log "$d" 2>/dev/null | awk -F: '
      /critical_warning/ {gsub(/[ \t]/,"",$2); cw=$2}
      /percentage_used/  {gsub(/[ \t]/,"",$2); pu=$2}
      /media_errors/     {gsub(/[ \t]/,"",$2); me=$2}
      END{printf "crit=%s used=%s media_err=%s", cw, pu, me}')
    note "$(basename "$d"): $s"
    case "$s" in *crit=0*) : ;; *) flag "$(basename "$d") SMART critical_warning nonzero or unread" ;; esac
  done
else
  note "nvme-cli absent (skip NVMe SMART)"
fi
if command -v smartctl >/dev/null 2>&1; then
  for d in /dev/sd[a-z]; do
    [ -e "$d" ] || continue
    h=$(smartctl -H "$d" 2>/dev/null | grep -iE 'overall-health|SMART Health Status|test result' | head -1 | sed 's/.*: *//')
    [ -z "$h" ] && h=$(smartctl -H -d sat "$d" 2>/dev/null | grep -iE 'overall-health|test result' | head -1 | sed 's/.*: *//')
    note "$(basename "$d"): SMART ${h:-n/a}"
    case "$h" in *FAIL*) flag "$(basename "$d") SMART: $h" ;; esac
  done
fi

sec docker
if command -v docker >/dev/null 2>&1; then
  r=$(docker ps -q 2>/dev/null | wc -l)
  u=$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)
  note "containers running: $r   unhealthy: $u"
  [ "$u" -eq 0 ] || flag "$u unhealthy container(s)"
else
  note "docker not present"
fi

sec memory-tuning
# multi-size THP. The point of this section is the RATIO, not the absolute counters: if the
# mid orders regress to "never" the fallback rate climbs back toward the ~81% that was
# measured before they were enabled, and that is the signal worth catching.
mthp_on=""
for o in 16 32 64; do
  e="/sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/enabled"
  [ -f "$e" ] || continue
  case "$(cat "$e")" in *"[always]"*|*"[inherit]"*) mthp_on="$mthp_on ${o}k" ;; esac
done
if [ -n "$mthp_on" ]; then
  note "mTHP orders enabled:$mthp_on"
else
  flag "mTHP mid orders (16k/32k/64k) all disabled - THP faults will fall back to 4k (nuc16pro-servermax-mm.service not applied?)"
fi
for o in 16 32 64 2048; do
  s="/sys/kernel/mm/transparent_hugepage/hugepages-${o}kB/stats"
  [ -d "$s" ] || continue
  a=$(cat "$s/anon_fault_alloc" 2>/dev/null || echo 0)
  f=$(cat "$s/anon_fault_fallback" 2>/dev/null || echo 0)
  t=$((a + f))
  if [ "$t" -gt 0 ]; then
    note "mTHP ${o}kB: alloc=$a fallback=$f ($((a * 100 / t))% success)"
  fi
done
# KSM is asserted off on purpose: measured general_profit was NEGATIVE on this box because
# Docker never opts memory in via MADV_MERGEABLE, so ksmd scans without merging.
if [ -f /sys/kernel/mm/ksm/run ]; then
  k=$(cat /sys/kernel/mm/ksm/run)
  if [ "$k" = "0" ]; then
    note "KSM: off (intended - measured negative general_profit on this workload)"
  else
    p=$(cat /sys/kernel/mm/ksm/general_profit 2>/dev/null || echo n/a)
    flag "KSM enabled (run=$k, general_profit=$p) - it merged ~15 pages at a net loss when last tested here"
  fi
fi
# DAMON proactive reclaim
if [ -f /sys/module/damon_reclaim/parameters/enabled ]; then
  de=$(cat /sys/module/damon_reclaim/parameters/enabled 2>/dev/null || echo '?')
  if [ "$de" = "Y" ]; then
    db=$(cat /sys/module/damon_reclaim/parameters/bytes_reclaimed_regions 2>/dev/null || echo 0)
    dq=$(cat /sys/module/damon_reclaim/parameters/nr_quota_exceeds 2>/dev/null || echo 0)
    note "DAMON reclaim: enabled, reclaimed=$((db / 1024 / 1024))MiB quota_exceeds=$dq"
  else
    note "DAMON reclaim: disabled (enabled=$de)"
  fi
fi
if [ -f /sys/module/zswap/parameters/max_pool_percent ]; then
  note "zswap pool: $(cat /sys/module/zswap/parameters/max_pool_percent)% compressor=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null)"
fi
zo=$(awk '/^zswpout/{o=$2} /^zswpin/{i=$2} END{if (o>0) printf "%d", i*100/o; else printf "0"}' /proc/vmstat)
note "zswap refault ratio: ${zo}% of writeouts were read back (high = pool under-sized for the working set)"

sec block-perf
for d in /sys/block/nvme[0-9]n[0-9] /sys/block/sd[a-z]; do
  [ -d "$d" ] || continue
  [ "$(cat "$d/queue/rotational" 2>/dev/null)" = "0" ] || continue
  n=$(basename "$d")
  w=$(cat "$d/queue/wbt_lat_usec" 2>/dev/null || echo n/a)
  ra=$(cat "$d/queue/rq_affinity" 2>/dev/null || echo n/a)
  s=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$d/queue/scheduler" 2>/dev/null)
  # wbt_lat_usec and rq_affinity are REPORTED, not asserted. Both were set to 0/2 in an
  # earlier round on mechanism grounds, then benchmarked with fio over 5 interleaved pairs
  # against the kernel defaults: read 161358 vs 164477 KB/s mean, write 133294 vs 131533,
  # with per-config spread wider than the difference. No measurable win, so the udev rule
  # was withdrawn and the kernel defaults are back. Left visible here so a future change
  # to these values is noticed, but there is nothing to flag.
  note "$n: sched=$s wbt_lat_usec=$w rq_affinity=$ra nr_requests=$(cat "$d/queue/nr_requests" 2>/dev/null)"
done

sec crypt-perf
if command -v dmsetup >/dev/null 2>&1; then
  ct=$(dmsetup table --target crypt 2>/dev/null)
  if [ -n "$ct" ]; then
    # Count crypt targets that are missing the workqueue-bypass flags. Every LUKS device on
    # this box sits under either the root LV or the media disks, so all container I/O pays
    # the dm-crypt path and the flags are worth asserting.
    tot=$(printf '%s\n' "$ct" | grep -c 'crypt ')
    ok=$(printf '%s\n' "$ct" | grep -c 'no_read_workqueue')
    note "dm-crypt targets with workqueue bypass: $ok/$tot"
    [ "$ok" -eq "$tot" ] || flag "$((tot - ok)) dm-crypt target(s) still using the internal workqueues (pending reboot, or crypttab not updated)"
  fi
fi

sec boot-order
# The tuning oneshots must land before dockerd starts the container fleet. This regressed
# silently once already (After=multi-user.target fired at 42.8s while docker started at
# 19.5s), and nothing else in the system reports it, so it is checked explicitly.
# The assertion is on the DECLARED ordering, not on this boot's timestamps. Timestamps are
# reported too, but they cannot be the test: the updater restarts these oneshots on every run
# (RemainAfterExit means a changed unit file would otherwise never re-apply), and any manual
# `systemctl restart` also moves them, so a timestamp-based check reports "started after
# docker" every time the units are legitimately re-run mid-uptime. The declared ordering is
# the thing that actually determines behaviour at the next boot, and it is what regressed
# last time.
dstart=$(systemctl show -p InactiveExitTimestampMonotonic --value docker.service 2>/dev/null)
for u in nuc16pro-servermax-cpupower.service nuc16pro-servermax-power.service nuc16pro-servermax-mm.service scx_loader.service; do
  systemctl cat "$u" >/dev/null 2>&1 || continue
  before=$(systemctl show -p Before --value "$u" 2>/dev/null)
  case "$before" in
    *docker.service*) ordering="declares Before=docker.service" ;;
    *) ordering="" ;;
  esac
  if [ -z "$ordering" ]; then
    flag "$u does not declare Before=docker.service - at the next boot the container fleet will start untuned"
    continue
  fi
  us=$(systemctl show -p InactiveExitTimestampMonotonic --value "$u" 2>/dev/null)
  if [ -n "$us" ] && [ "$us" -gt 0 ] 2>/dev/null && [ -n "$dstart" ] && [ "$dstart" -gt 0 ] 2>/dev/null && [ "$us" -lt "$dstart" ]; then
    note "$u: $ordering, applied $(( (dstart - us) / 1000000 ))s before docker this boot"
  else
    note "$u: $ordering (re-run since boot, so this boot's timestamp is not the boot-order signal)"
  fi
done
# bluetooth MUST stay enabled: Home Assistant uses the adapter (the container runs
# privileged with net=host and /run/dbus bind-mounted, and talks to hci0 through BlueZ).
# It is noisy in the journal on a box with no paired peripherals nearby, but that is cosmetic
# and NOT a reason to disable it. Flag the opposite condition instead - if bluetooth is off,
# HA's BLE integrations are silently broken.
if systemctl cat bluetooth.service >/dev/null 2>&1; then
  if systemctl is-enabled --quiet bluetooth.service 2>/dev/null; then
    note "bluetooth: enabled (required by Home Assistant BLE)"
  else
    flag "bluetooth.service is NOT enabled - Home Assistant BLE devices will not work"
  fi
fi

echo "==== summary: warnings=$warn ===="
exit 0
HEALTHCHECK

install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-healthcheck.service <<'HC_SVC'
[Unit]
Description=NUC 16 Pro ServerMax post-boot health report (read-only; logs to journal)
After=multi-user.target docker.service nuc16pro-scx-server.service
ConditionPathExists=/usr/local/sbin/nuc16pro-healthcheck

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nuc16pro-healthcheck
Nice=10
IOSchedulingClass=idle
HC_SVC

install -Dm644 /dev/stdin /etc/systemd/system/nuc16pro-healthcheck.timer <<'HC_TIMER'
[Unit]
Description=Run the NUC 16 Pro ServerMax health report post-boot and daily

[Timer]
OnBootSec=5min
OnCalendar=daily
Persistent=true
RandomizedDelaySec=45

[Install]
WantedBy=timers.target
HC_TIMER

systemctl daemon-reload
systemctl enable nuc16pro-healthcheck.timer || true
systemctl start nuc16pro-healthcheck.timer || true

msg "installing RDP software-Vulkan workaround (Panther Lake Xe3)"
# gnome-remote-desktop's RDP --handover daemon SIGSEGVs inside the Intel Mesa Vulkan
# driver (libvulkan_intel.so) on Xe3 while setting up the PipeWire capture pipeline:
# auth succeeds, the session daemon dies, the client sees a black screen and drops.
# GRD 50 has no gsettings/env switch to disable its Vulkan stage, so force its Vulkan
# onto the software rasteriser (lavapipe). Applied only where g-r-d is installed.
if systemctl cat gnome-remote-desktop.service >/dev/null 2>&1; then
  install -Dm644 /dev/stdin /etc/systemd/system/gnome-remote-desktop.service.d/10-software-vulkan.conf <<'GRD_VK'
# Panther Lake (Xe3) workaround for GNOME Remote Desktop RDP.
#
# gnome-remote-desktop's per-session RDP daemon (gnome-remote-desktop-daemon
# --handover) SIGSEGVs inside the Intel Mesa Vulkan driver (libvulkan_intel.so)
# while building the PipeWire screen-capture pipeline on this Xe3 iGPU. The RDP
# client authenticates, the session daemon dies mid-startup, the client sees a
# black screen and is dropped. GRD 50 exposes no gsettings/env switch to disable
# its Vulkan colour-convert stage, so pin its Vulkan loader to the software
# rasteriser (lavapipe): the crashing Intel ICD is then never loaded by GRD.
#
# VA-API hardware transcode is unaffected - it uses the iHD driver via libva, a
# different stack from the Vulkan loader. Cost is CPU-side colour conversion; the
# H.264 encode stays on the GPU. Remove this drop-in (and the matching lines in
# /etc/environment) once Mesa ANV / kernel xe stabilise for Xe3, to regain
# GPU-accelerated conversion.
[Service]
Environment=VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json
Environment=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
GRD_VK
  # /etc/environment (pam_env) also carries it into the GDM-spawned handover session,
  # which runs under a GDM dynamic user rather than the system service's environment.
  for kv in \
    "VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json" \
    "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json"; do
    grep -q "^${kv%%=*}=" /etc/environment 2>/dev/null || echo "$kv" >> /etc/environment
  done
  systemctl daemon-reload
  systemctl try-restart gnome-remote-desktop.service || true
else
  echo "gnome-remote-desktop not present; skipping RDP Vulkan workaround"
fi

msg "applying sysctl and udev"
sysctl --system       || true
udevadm control --reload-rules || true
udevadm trigger       || true
udevadm settle --timeout=30 || true

msg "configuring grub"

if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
  sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=saved|' /etc/default/grub
else
  echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
fi

if grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
  sed -i 's|^GRUB_SAVEDEFAULT=.*|GRUB_SAVEDEFAULT=false|' /etc/default/grub
else
  echo 'GRUB_SAVEDEFAULT=false' >> /etc/default/grub
fi

# direct boot, no menu (hold Shift at power-on to show GRUB when needed)
for kv in "GRUB_TIMEOUT=0" "GRUB_TIMEOUT_STYLE=hidden"; do
  key="${kv%%=*}"
  if grep -q "^${key}=" /etc/default/grub; then
    sed -i "s|^${key}=.*|${kv}|" /etc/default/grub
  else
    echo "$kv" >> /etc/default/grub
  fi
done

# threadirqs: spread interrupts across P/E/LP-E cores for better I/O latency
# nvme_core.default_ps_max_latency_us=0: disable NVMe power states (Gen4/Gen5 max throughput)
# preempt=lazy: this PREEMPT_DYNAMIC build (CONFIG_PREEMPT base) exposes 'full' and
#   'lazy' as preempt modes; 'none'/'voluntary' are NOT built, so an earlier preempt=none
#   was rejected and the kernel ran 'full'. preempt=lazy IS honored (verified at cold
#   boot) and is the throughput-lean server pick: fair-class tasks run fuller slices
#   while RT-class threaded IRQs still preempt immediately (low latency). scx_bpfland
#   --server is the real scheduler and dominates regardless. Runtime-switchable via
#   /sys/kernel/debug/sched/preempt.
# mitigations=auto: keep CPU vulnerability mitigations on (box is internet-exposed).
# No i915.enable_guc=3: Panther Lake iGPU uses xe driver, not i915
# zswap.zpool dropped 2026-06-25: z3fold was removed from the kernel (gone by 7.x), so
# zswap.zpool=z3fold was inert - zswap silently fell back (live check showed zpool empty,
# z3fold module absent). Omitting it uses the compiled default zsmalloc, which has the best
# density anyway. zswap.zpool stays in the dedup list below so the stale z3fold token is
# stripped from any existing /etc/default/grub on the next update.
# tsc=reliable: skip the clocksource watchdog - TSC here is constant/nonstop/known-freq.
# nmi_watchdog=0: free the per-core perf counter the hard-lockup detector holds; a headless
#   server does not need NMI lockup detection. mitigations stays =auto (internet-exposed).
# splash is stripped below (not re-added): the plymouth splash starves multi-user.target on
#   this headless box, delaying the tuning oneshots.
# zswap.max_pool_percent raised 20 -> 30 (2026-08-23). Measured on this box: 12.77M zswap
# writeouts against 7.88M readins, i.e. pages are being pushed out and pulled straight back,
# which is what a pool that is too small to hold the working set looks like. At 20% of 30GB
# the compressed cache tops out around 6GB and overflow goes to disk swap on the LUKS root;
# 30% gives it ~9GB before it has to touch the encrypted device. The pool is a ceiling, not a
# reservation, so it costs nothing when the box is not under memory pressure. Kept at 30 and
# not higher because page cache on this media server is worth real money too.
GRUB_CMDLINE_ADD="threadirqs usbcore.autosuspend=-1 nvme_core.default_ps_max_latency_us=0 zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=zstd zswap.max_pool_percent=30 mitigations=auto intel_pstate=active preempt=lazy tsc=reliable nmi_watchdog=0"

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
  CURRENT="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | \
    sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"/\1/')"

  # Remove stale Lenovo/Tiger Lake params and any we're about to re-add. 'splash' is in the
  # list but NOT in GRUB_CMDLINE_ADD, so it is stripped and stays gone (headless plymouth fix).
  for param in i915.enable_guc threadirqs usbcore.autosuspend nvme_core.default_ps_max_latency_us \
               zswap.enabled zswap.shrinker_enabled zswap.compressor \
               zswap.max_pool_percent zswap.zpool rcutree.enable_rcu_lazy \
               mitigations intel_pstate preempt tsc nmi_watchdog splash; do
    CURRENT="$(echo "$CURRENT" | sed -E "s/(^| )${param}=[^ ]+//g; s/(^| )${param}( |$)/ /g")"
  done

  NEW="$(echo "$CURRENT $GRUB_CMDLINE_ADD" | xargs)"
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW\"|" \
    /etc/default/grub
else
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$GRUB_CMDLINE_ADD\"" >> /etc/default/grub
fi

if [ -f /etc/initramfs-tools/modules ]; then
  grep -qxF "lz4" /etc/initramfs-tools/modules || echo "lz4" >> /etc/initramfs-tools/modules
  grep -qxF "asus_wmi" /etc/initramfs-tools/modules || echo "asus_wmi" >> /etc/initramfs-tools/modules
fi

purge_old_custom_kernels "$TAG_KVER"

msg "updating initramfs and grub"
update-initramfs -u -k all
update-grub

msg "setting grub default"

ALL_TARGET_KERNELS="$(
  ls /boot/vmlinuz-*cachyos*nuc16pro*servermax* 2>/dev/null |
    sed 's|/boot/vmlinuz-||' |
    sort -V
)"

# Pick the kernel matching this release's version (TAG_KVER), not the highest
# sort order. An older RC left in /boot (e.g. 7.1.0-rc2) sorts ABOVE the newer
# stable target (7.1.0) under sort -V, so tail -n1 would wrongly select the RC
# and set GRUB to boot it. The first ascending-sorted entry containing TAG_KVER
# is the stable target (it sorts below its own -rc), matching the keep logic in
# purge_old_custom_kernels.
TARGET_KERNEL="$(printf '%s\n' "$ALL_TARGET_KERNELS" | grep -F "$TAG_KVER" | head -n1 || true)"

# Fallback: tag version not found verbatim in any vmlinuz name -> highest sort.
[ -z "${TARGET_KERNEL:-}" ] && TARGET_KERNEL="$(printf '%s\n' "$ALL_TARGET_KERNELS" | tail -n1)"

if [ -z "${TARGET_KERNEL:-}" ]; then
  echo "error: CachyOS kernel not found in /boot"
  ls -lh /boot/vmlinuz-* || true
  exit 1
fi

echo "target: $TARGET_KERNEL"

SUBMENU="$(awk -F"'" '/submenu / {print $2; exit}' /boot/grub/grub.cfg || true)"

# index() for fixed-string match - version dots are regex wildcards
ENTRY="$(awk -F"'" -v k="$TARGET_KERNEL" \
  '/menuentry / && index($0, k) {print $2; exit}' /boot/grub/grub.cfg || true)"

if [ -z "${ENTRY:-}" ]; then
  echo "error: GRUB entry not found for $TARGET_KERNEL"
  awk -F"'" '/menuentry / {print $2}' /boot/grub/grub.cfg || true
  exit 1
fi

GRUB_ENTRY="${ENTRY}"
[ -n "${SUBMENU:-}" ] && GRUB_ENTRY="${SUBMENU}>${ENTRY}"

grub-set-default "$GRUB_ENTRY"
echo "grub default: $GRUB_ENTRY"
grub-editenv list || true

echo "$TAG" > "$LAST_TAG_FILE"

msg "status"
dpkg -l | grep -iE 'cachyos|linux-image|linux-headers' || true
ls -lh /boot | grep -E 'cachyos|vmlinuz|initrd' || true

systemctl status nuc16pro-scx-server.service --no-pager -l | head -60 || true
systemctl status scx_loader.service --no-pager -l | head -30 2>/dev/null || true
[ -r /sys/kernel/sched_ext/state ] && echo "sched_ext: $(cat /sys/kernel/sched_ext/state)"

# RAPL power limits readback: confirm BIOS didn't lock/override our writes
if [ -d /sys/class/powercap/intel-rapl/intel-rapl:0 ]; then
  p=/sys/class/powercap/intel-rapl/intel-rapl:0
  echo "rapl pl1:   $(cat "$p/constraint_0_power_limit_uw")uW"
  echo "rapl pl2:   $(cat "$p/constraint_1_power_limit_uw")uW"
  echo "rapl tau1:  $(cat "$p/constraint_0_time_window_us")us"
  echo "rapl tau2:  $(cat "$p/constraint_1_time_window_us")us"
else
  echo "rapl:       sysfs not available (CONFIG_POWERCAP/INTEL_RAPL_CORE not loaded?)"
fi
[ -r /sys/firmware/acpi/platform_profile ] && echo "platform:   $(cat /sys/firmware/acpi/platform_profile)" || true

echo "installed:  $TAG"
echo "kernel:     $TARGET_KERNEL"
echo "backup:     $BACKUP_DIR"
echo "log:        $LOG"

if [ "$NEED_REBOOT_ONLY" -eq 2 ]; then
  echo "already on target kernel, tuning applied, no reboot"
else
  sync
  systemctl reboot
fi
