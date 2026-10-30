# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Probes: what to ask a fleet, by name.

`qd probe NAME... -s hosts.txt` runs each one across the fleet and files it
as a run named after the probe, so `qd show mem`, `qd compare facts
cpu.busy_pct --last 5` and `provost show sysctl` all find it.

Three kinds, and the first two are the toolchain's own instruments, not
copies of them:

  script   a binnacle tool, single-file and stdlib-only, pushed to every
           host and run there by qd's own fan-out: why-slow --facts (two
           hundred readings of CPU, memory, disks, network, limits,
           cgroups, thermals), why-slow's findings, skew's clock check.
           The hosts need python3; the tool needs to be installed here.
  tool     a tool that drives the fleet itself, run here and read back as
           `qd do` would: dcprobe scan and preflight, binnacle's reachable.
  command  a shell command for what none of them measures (GPUs, sysctl
           settings, failed units, mounts, block devices, packages ...),
           written to answer in `key: value` lines or one table with a
           header, the two shapes provost reads best.  POSIX sh (dash,
           busybox ash and bash alike), reading /proc and /sys where a
           command might be missing.  A host without the thing says so in
           a column rather than failing, and a value that could not be read
           is left out -- never written as 0 or "unknown".

A probe that is not available here (its tool not installed) says what to
install instead of running half a fleet.
"""

import os

from .common import die

# why-slow --facts is one host's readings, flat but for a list or two (the
# top processes by memory); provost files a list a row an element, which
# makes a host several rows of its own readings.  Each list goes in as the
# JSON text it was, so a host is one row and nothing is lost.  The tool's
# own output is taken first, so its exit status and its stderr are the
# host's, not the filter's.
LISTS_AS_TEXT = ("o=$({cmd}) && printf '%s\\n' \"$o\" | python3 -c "
                 "'import json, sys; d = json.load(sys.stdin); "
                 "print(json.dumps(dict((k, json.dumps(v, sort_keys=True) "
                 "if isinstance(v, (list, dict)) else v) "
                 "for k, v in d.items())))'")


def script_command(how, command):
    """A script probe's command: the tool, or the tool run through the
    filter its catalogue entry names ({cmd} in it)."""
    return how[2].replace("{cmd}", command) if len(how) > 2 else command

# name -> (kind, how, what, needs)
#   command: how is the remote shell command
#   script:  how is (binnacle module, its arguments[, a filter after it])
#   tool:    how is (tool name, argv after it with {hosts} and {out})
CATALOGUE = [
    # -- the toolchain's instruments ----------------------------------------
    ("facts", "script", ("binnacle.why_slow", ["--facts"], LISTS_AS_TEXT),
     "why-slow's readings: cpu.*, mem.*, disk.*, net.*, fs.*, lim.*, cg.*, "
     "therm.* (one row per host)", "python3 on the hosts; binnacle here"),
    ("why-slow", "script", ("binnacle.why_slow", ["--csv"]),
     "why-slow's findings per host: rule, severity, detail, fix",
     "python3 on the hosts; binnacle here"),
    ("skew", "script", ("binnacle.skew", ["--csv"]),
     "clock and time sync: offset, sources, stratum (skew's findings)",
     "python3 on the hosts; binnacle here"),
    ("health", "tool", ("dcprobe", ["scan", "--servers", "{hosts}", "-o",
                                    "{out}"]),
     "dcprobe scan: load, CPU, iowait, steal, memory, swap, disk, NIC link, "
     "speed, drops, errors, kernel errors, inventory",
     "datacenter-layout-viewer here (dcprobe)"),
    ("preflight", "tool", ("dcprobe", ["preflight", "--servers", "{hosts}",
                                       "-o", "{out}"]),
     "dcprobe preflight: ssh, clock skew, nofile, bind, tools -- before a "
     "test", "datacenter-layout-viewer here (dcprobe)"),
    ("reach", "tool", ("reachable", ["{hosts}", "--csv", "{out}"]),
     "binnacle reachable: ping and ssh per host, and why not",
     "binnacle here"),
    # -- what nothing else measures -----------------------------------------
    ("os", "command", r"""
os=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s)
printf 'os: %s\nkernel: %s\narch: %s\n' "$os" "$(uname -r)" "$(uname -m)"
u=$(cut -d. -f1 /proc/uptime 2>/dev/null)
[ -z "$u" ] || printf 'uptime_s: %s\n' "$u"
v=$(systemd-detect-virt 2>/dev/null)
[ -z "$v" ] || printf 'virt: %s\n' "$v"
""".strip(),
     "distribution, kernel, architecture, uptime, virtualisation", ""),
    ("sysctl", "command",
     "for k in net.core.somaxconn net.core.rmem_max net.core.wmem_max "
     "net.core.netdev_max_backlog net.ipv4.tcp_rmem net.ipv4.tcp_wmem "
     "net.ipv4.tcp_congestion_control net.ipv4.ip_local_port_range "
     "net.ipv4.tcp_max_syn_backlog vm.swappiness vm.dirty_ratio "
     "vm.dirty_background_ratio vm.overcommit_memory vm.max_map_count "
     "fs.file-max kernel.pid_max kernel.numa_balancing; do "
     "v=$(tr '\\t' ' ' 2>/dev/null < \"/proc/sys/$(echo \"$k\" | tr . /)\"); "
     "if [ -n \"$v\" ]; then printf '%s: %s\\n' \"$k\" \"$v\"; fi; done",
     "the kernel settings that move performance (network buffers, "
     "backlogs, congestion control, VM, file and pid limits)", ""),
    ("services", "command", r"""
if command -v systemctl >/dev/null 2>&1; then
  s=$(systemctl is-system-running 2>/dev/null)
  case "$s" in
  running|degraded|starting|initializing|maintenance|stopping)
    f=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null |
        awk '{print $1}')
    printf 'system_state: %s\nfailed_units: %s\n' "$s" \
      "$(printf '%s' "$f" | grep -c .)"
    [ -z "$f" ] || printf 'failed: %s\n' "$(echo $f)" ;;
  *) printf 'system_state: %s\n' "${s:-unknown}" ;;
  esac
else
  echo 'system_state: no systemd'
fi
""".strip(),
     "systemd's state and failed units (counted only where systemd runs)",
     ""),
    ("gpu", "command", r"""
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo 'nvidia_smi: absent'
elif o=$(nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,ecc.errors.uncorrected.volatile.total --format=csv,noheader,nounits 2>&1); then
  echo 'index,name,temp_c,util_pct,mem_used_mib,mem_total_mib,power_w,ecc_errors'
  printf '%s\n' "$o" | sed 's/, */,/g; s/\[[^],]*\]//g'
else
  echo 'nvidia_smi: failed'
  printf 'error: %s\n' "$(printf '%s\n' "$o" | head -1)"
  exit 1
fi
""".strip(),
     "NVIDIA GPUs: temperature, utilisation, memory, power, ECC errors", ""),
    ("mounts", "command", r"""
printf 'target\tfstype\tsource\toptions\n'
awk '$3 !~ /^(proc|sysfs|cgroup2?|tmpfs|devtmpfs|devpts|mqueue|debugfs|tracefs|securityfs|pstore|bpf|configfs|fusectl|hugetlbfs|autofs|binfmt_misc|nsfs|overlay|rpc_pipefs|efivarfs|ramfs|selinuxfs)$/ {
  print $2 "\t" $3 "\t" $1 "\t" $4 }' /proc/self/mounts
""".strip(),
     "real filesystems and their mount options (from /proc)", ""),
    ("disks", "command", r"""
echo 'name,size_bytes,rota,type,model'
for d in /sys/block/*; do
  n=${d##*/}
  case "$n" in loop*|ram*) continue ;; esac
  z=$(cat "$d/size" 2>/dev/null)
  [ -n "$z" ] || continue
  case "$n" in nbd*) [ "$z" != 0 ] || continue ;; esac
  t=disk
  case "$n" in dm-*) t=dm ;; md*) t=raid ;; zram*) t=zram ;; sr*) t=rom ;; esac
  m=$(cat "$d/device/model" 2>/dev/null | tr -s ' ,' '  ' | sed 's/^ *//; s/ *$//')
  echo "$n,$((z * 512)),$(cat "$d/queue/rotational" 2>/dev/null),$t,$m"
done
""".strip(),
     "block devices: size in bytes, spinning or not, model (from /sys)", ""),
    ("packages", "command", r"""
if command -v dpkg-query >/dev/null 2>&1; then
  m=dpkg; o=$(dpkg-query -f '.\n' -W 2>/dev/null) && n=$(printf '%s\n' "$o" | grep -c .)
  # the flag is written by update-notifier's kernel hook: without it, its
  # absence says nothing
  if [ -f /var/run/reboot-required ]; then r=yes
  elif [ -x /usr/share/update-notifier/notify-reboot-required ]; then r=no; fi
elif command -v rpm >/dev/null 2>&1; then
  m=rpm; o=$(rpm -qa 2>/dev/null) && n=$(printf '%s\n' "$o" | grep -c .)
  if command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1
    case $? in 0) r=no ;; 1) r=yes ;; esac
  fi
elif command -v apk >/dev/null 2>&1; then
  m=apk; o=$(apk info 2>/dev/null) && n=$(printf '%s\n' "$o" | grep -c .)
elif command -v pacman >/dev/null 2>&1; then
  m=pacman; o=$(pacman -Q 2>/dev/null) && n=$(printf '%s\n' "$o" | grep -c .)
else
  m=none
fi
# a tool that failed has counted nothing: said, not written as 0
[ "$m" = none ] || [ -n "$n" ] || echo "packages_error: $m failed"
echo "manager: $m"
[ -z "$n" ] || echo "packages: $(echo $n)"
[ -z "$r" ] || echo "reboot_required: $r"
""".strip(),
     "package manager (dpkg, rpm, apk, pacman), how many installed, whether "
     "a reboot is pending where that can be told", ""),
    ("numa", "command", r"""
[ ! -d /sys/devices/system/node ] ||
  echo "numa_nodes: $(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)"
c=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)
[ -z "$c" ] || echo "cpus: $c"
b=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)
[ -z "$b" ] || echo "balancing: $b"
""".strip(),
     "NUMA nodes, CPUs, automatic balancing", ""),
    ("pagecache", "command",
     "grep -E '^(MemTotal|MemAvailable|Buffers|Cached|Dirty|Writeback|"
     "Shmem|Slab|SReclaimable|HugePages_Total|HugePages_Free|Hugepagesize)"
     ":' /proc/meminfo",
     "page cache, dirty and writeback, slab, hugepages (kB)", ""),
    ("listen", "command", r"""
if command -v ss >/dev/null 2>&1; then
  o=$(ss -ltnup 2>/dev/null) || o=failed
  [ "$o" = failed ] && l="ss failed" ||
  l=$(printf '%s\n' "$o" | awk 'NR > 1 {p = $NF
    sub(/^users:\(\("/, "", p); sub(/".*/, "", p)
    if (p == $5 || p == $6) p = ""
    print $1 "," $5 "," p}')
elif command -v netstat >/dev/null 2>&1; then
  o=$(netstat -ltnup 2>/dev/null) || o=failed
  [ "$o" = failed ] && l="netstat failed" ||
  l=$(printf '%s\n' "$o" | awk '$1 ~ /^(tcp|udp)/ {p = ""
    for (i = 6; i <= NF; i++) if ($i ~ /^[0-9]+\//) {
      p = $i; sub(/^[0-9]+\//, "", p); sub(/:$/, "", p); break }
    print $1 "," $4 "," p}')
else
  l=none
fi
if [ "$l" = none ]; then
  echo 'listen_tool: none (no ss, no netstat)'
elif [ "$l" = "ss failed" ] || [ "$l" = "netstat failed" ]; then
  echo "listen_tool: $l"
elif [ -n "$l" ]; then
  echo 'proto,local,process'; echo "$l"
else
  echo 'listening: 0'
fi
""".strip(),
     "listening sockets and who holds them (ss, else netstat)", ""),
    ("containers", "command", r"""
for c in docker podman; do
  command -v $c >/dev/null 2>&1 || continue
  if o=$($c ps -q 2>/dev/null); then
    echo "${c}_running: $(printf '%s' "$o" | grep -c .)"
  else
    echo "${c}: installed, ps refused (no access to its socket?)"
  fi
done
echo 'containers_checked: yes'
""".strip(),
     "running containers under docker and podman (a count only where ps "
     "answers)", ""),
]

NAMES = [p[0] for p in CATALOGUE]

GROUPS = {
    "inventory": ["os", "disks", "mounts", "numa", "gpu", "packages"],
    "settings": ["sysctl", "numa"],
    "state": ["services", "listen", "containers", "pagecache"],
}


def get(name):
    for p in CATALOGUE:
        if p[0] == name:
            return p
    die("no probe %r: `qd probe` lists them (%s)" % (
        name, ", ".join(NAMES + sorted(GROUPS))))


def expand(names):
    out = []
    for n in names:
        for m in GROUPS.get(n, [n]):
            get(m)
            if m not in out:
                out.append(m)
    return out


def script_path(module):
    """The file of a single-file tool, to push: binnacle's are stdlib
    Python 3.6+, made to be copied to a host and run there."""
    try:
        import importlib.util
        spec = importlib.util.find_spec(module)
    except (ImportError, ValueError, AttributeError):
        spec = None
    if spec is None or not spec.origin or not os.path.isfile(spec.origin):
        return None
    return spec.origin


def available(p):
    """(True, how) or (False, what to install)."""
    from . import tools
    name, kind, how, _, needs = p
    if kind == "command":
        return True, "shell"
    if kind == "script":
        path = script_path(how[0])
        if path:
            return True, path
        return False, " -- ".join(x for x in (needs, "pip install binnacle")
                                  if x)
    argv = tools.find_tool(how[0])
    if argv:
        return True, " ".join(argv)
    return False, tools.install_hint(how[0]) or needs
