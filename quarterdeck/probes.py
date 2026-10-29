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
           header, the two shapes provost reads best.  POSIX sh; a host
           without the thing says so in a column rather than failing.

A probe that is not available here (its tool not installed) says what to
install instead of running half a fleet.
"""

import os

from .common import die

# name -> (kind, how, what, needs)
#   command: how is the remote shell command
#   script:  how is (binnacle module, its arguments)
#   tool:    how is (tool name, argv after it with {hosts} and {out})
CATALOGUE = [
    # -- the toolchain's instruments ----------------------------------------
    ("facts", "script", ("binnacle.why_slow", ["--facts"]),
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
    ("reach", "tool", ("reachable", ["{hosts}", "--csv", "-o", "{out}"]),
     "binnacle reachable: ping and ssh per host, and why not",
     "binnacle here"),
    # -- what nothing else measures -----------------------------------------
    ("os", "command",
     "printf 'os: %s\\nkernel: %s\\narch: %s\\nuptime_s: %s\\nvirt: %s\\n' "
     "\"$( (. /etc/os-release 2>/dev/null && echo \"$PRETTY_NAME\") || "
     "uname -s)\" \"$(uname -r)\" \"$(uname -m)\" "
     "\"$(cut -d. -f1 /proc/uptime 2>/dev/null)\" "
     "\"$(systemd-detect-virt 2>/dev/null || echo unknown)\"",
     "distribution, kernel, architecture, uptime, virtualisation", ""),
    ("sysctl", "command",
     "for k in net.core.somaxconn net.core.rmem_max net.core.wmem_max "
     "net.core.netdev_max_backlog net.ipv4.tcp_rmem net.ipv4.tcp_wmem "
     "net.ipv4.tcp_congestion_control net.ipv4.ip_local_port_range "
     "net.ipv4.tcp_max_syn_backlog vm.swappiness vm.dirty_ratio "
     "vm.dirty_background_ratio vm.overcommit_memory vm.max_map_count "
     "fs.file-max kernel.pid_max kernel.numa_balancing; do "
     "printf '%s: %s\\n' \"$k\" \"$(sysctl -n \"$k\" 2>/dev/null | "
     "tr '\\t' ' ')\"; done",
     "the kernel settings that move performance (network buffers, "
     "backlogs, congestion control, VM, file and pid limits)", ""),
    ("services", "command",
     "f=$(systemctl list-units --state=failed --no-legend --plain "
     "2>/dev/null | awk '{print $1}'); "
     "s=$(systemctl is-system-running 2>/dev/null); [ -n \"$s\" ] || "
     "s=unknown; "
     "printf 'failed_units: %s\\nfailed: %s\\nsystem_state: %s\\n' "
     "\"$(printf '%s' \"$f\" | grep -c .)\" \"$(echo $f)\" \"$s\"",
     "systemd's failed units and overall state", ""),
    ("gpu", "command",
     "if command -v nvidia-smi >/dev/null 2>&1; then "
     "echo 'index,name,temp_c,util_pct,mem_used_mib,mem_total_mib,"
     "power_w,ecc_errors'; nvidia-smi --query-gpu=index,name,"
     "temperature.gpu,utilization.gpu,memory.used,memory.total,"
     "power.draw,ecc.errors.uncorrected.volatile.total "
     "--format=csv,noheader,nounits | sed 's/, */,/g'; "
     "else echo 'gpu: none'; fi",
     "NVIDIA GPUs: temperature, utilisation, memory, power, ECC errors", ""),
    ("mounts", "command",
     "printf 'target\\tfstype\\tsource\\toptions\\n'; findmnt -rn -o "
     "TARGET,FSTYPE,SOURCE,OPTIONS 2>/dev/null | grep -vE ' (proc|sysfs|"
     "cgroup2?|tmpfs|devtmpfs|devpts|mqueue|debugfs|tracefs|securityfs|"
     "pstore|bpf|configfs|fusectl|hugetlbfs|autofs|binfmt_misc|nsfs|"
     "overlay) ' | tr ' ' '\\t'",
     "real filesystems and their mount options", ""),
    ("disks", "command",
     "echo 'name,size,rota,type,model'; lsblk -dn -o NAME,SIZE,ROTA,TYPE,"
     "MODEL 2>/dev/null | awk '{m=\"\"; for (i=5;i<=NF;i++) m=m (i>5?\" "
     "\":\"\") $i; print $1\",\"$2\",\"$3\",\"$4\",\"m}'",
     "block devices: size, spinning or not, model", ""),
    ("packages", "command",
     "if command -v dpkg-query >/dev/null 2>&1; then m=dpkg; "
     "n=$(dpkg-query -f '.\\n' -W 2>/dev/null | wc -l); "
     "elif command -v rpm >/dev/null 2>&1; then m=rpm; "
     "n=$(rpm -qa 2>/dev/null | wc -l); else m=none; n=; fi; "
     "printf 'manager: %s\\npackages: %s\\nreboot_required: %s\\n' "
     "\"$m\" \"$n\" \"$( [ -f /var/run/reboot-required ] && echo yes || "
     "echo no)\"",
     "package manager, how many installed, whether a reboot is pending", ""),
    ("numa", "command",
     "printf 'numa_nodes: %s\\ncpus: %s\\nbalancing: %s\\n' "
     "\"$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)\" "
     "\"$(nproc 2>/dev/null)\" "
     "\"$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)\"",
     "NUMA nodes, CPUs, automatic balancing", ""),
    ("pagecache", "command",
     "grep -E '^(MemTotal|MemAvailable|Buffers|Cached|Dirty|Writeback|"
     "Shmem|Slab|SReclaimable|HugePages_Total|HugePages_Free|Hugepagesize)"
     ":' /proc/meminfo",
     "page cache, dirty and writeback, slab, hugepages (kB)", ""),
    ("listen", "command",
     "l=$(ss -ltnupH 2>/dev/null | awk '{p=$NF; "
     "sub(/^users:\\(\\(\"/, \"\", p); sub(/\".*/, \"\", p); "
     "print $1\",\"$5\",\"p}'); if [ -n \"$l\" ]; then "
     "echo 'proto,local,process'; echo \"$l\"; else "
     "echo 'listening: 0'; fi",
     "listening sockets and who holds them", ""),
    ("containers", "command",
     "for c in docker podman; do if command -v $c >/dev/null 2>&1; then "
     "printf '%s_running: %s\\n' $c \"$($c ps -q 2>/dev/null | wc -l)\"; "
     "fi; done; printf 'containers_checked: yes\\n'",
     "running containers under docker and podman", ""),
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
        return (True, path) if path else (False, needs or "pip install "
                                          "binnacle")
    argv = tools.find_tool(how[0])
    if argv:
        return True, " ".join(argv)
    return False, tools.install_hint(how[0]) or needs
