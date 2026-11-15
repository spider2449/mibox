"""Offline config gate for the pi2-os-style container profile; no device access."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# This is the selected overlay/bridge/seccomp profile, not every possible
# Docker configuration. Modules need separate matching-module/load evidence.
GROUPS = {
    'isolation': ['NAMESPACES', 'UTS_NS', 'IPC_NS', 'PID_NS', 'NET_NS'],
    'resources': ['CGROUPS', 'MEMCG', 'CGROUP_SCHED', 'CFS_BANDWIDTH',
                  'CPUSETS', 'CGROUP_PIDS'],
    'storage': ['OVERLAY_FS', 'EXT4_FS', 'TMPFS', 'TMPFS_XATTR'],
    'network': ['INET', 'BRIDGE', 'BRIDGE_NETFILTER', 'VETH', 'NETFILTER',
                'NF_CONNTRACK', 'NF_NAT', 'IP_NF_IPTABLES', 'IP_NF_FILTER',
                'IP_NF_TARGET_MASQUERADE', 'NETFILTER_XT_MATCH_ADDRTYPE',
                'NETFILTER_XT_MATCH_CONNTRACK'],
    'security': ['SECCOMP', 'SECCOMP_FILTER', 'KEYS'],
    'terminal': ['UNIX98_PTYS', 'DEVPTS_MULTIPLE_INSTANCES'],
}
LEGACY_GROUPS = {
    group: [name for name in names if name not in {'CGROUP_PIDS', 'OVERLAY_FS'}]
    for group, names in GROUPS.items()
}


def audit(path, profile='pi2-os'):
    if profile not in {'pi2-os', 'legacy-vfs'}:
        raise ValueError('unknown container kernel profile')
    raw = path.read_bytes()
    config = {}
    lines = {}
    text = raw.decode('utf-8-sig')
    for number, line in enumerate(text.splitlines(), 1):
        match = re.fullmatch(r'(CONFIG_\w+)=(.*)', line)
        disabled = re.fullmatch(r'# (CONFIG_\w+) is not set', line)
        if match or disabled:
            key, value = match.groups() if match else (disabled[1], 'n')
            if key in config and config[key] != value:
                raise ValueError(f'conflicting values for {key} at line {number}')
            config[key], lines[key] = value, number
    if not config:
        raise ValueError('no kernel configuration entries found')
    checks = []
    for group, names in (GROUPS if profile == 'pi2-os' else LEGACY_GROUPS).items():
        for name in names:
            key = 'CONFIG_' + name
            value = config.get(key, 'UNKNOWN')
            checks.append(dict(group=group, key=key, value=value,
                               line=lines.get(key),
                               status='PASS' if value == 'y' else
                               'BLOCKED' if value == 'n' else 'UNKNOWN'))
    version = re.search(r'^# Linux/\S+ (\S+) Kernel Configuration$', text, re.M)
    return dict(schema=1, config=str(path), config_sha256=hashlib.sha256(raw).hexdigest(),
                kernel_version=version[1] if version else 'UNKNOWN',
                profile=('pi2-os-style overlay/bridge/seccomp container host' if profile == 'pi2-os'
                         else 'legacy cgroup-v1/VFS/bridge/seccomp development host'),
                config_gate='PASS' if all(c['status'] == 'PASS' for c in checks)
                            else 'NOT READY',
                runtime_readiness='NOT READY', physical_validation=False,
                limitations=[] if profile == 'pi2-os' else [
                    'No overlayfs, cgroup v2 or pids-limit requirement in this profile.',
                    'A PASS does not establish compatibility with any Docker engine version.'],
                runtime_gates={k: 'UNKNOWN' for k in [
                    ('cgroup_v2_mount_and_controllers' if profile == 'pi2-os'
                     else 'cgroup_v1_mount_and_controllers'), 'kernel_board_boot',
                    'engine_binary_compatibility', 'storage_backing_filesystem',
                    'image_pull_and_run', 'bridge_and_published_port',
                    'resource_limits', 'persistent_volume_and_restart']},
                checks=checks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT /
                        'artifacts/platform/2026-11-14/stock-kernel.config')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--profile', choices=['pi2-os', 'legacy-vfs'], default='pi2-os')
    args = parser.parse_args()
    report = audit(args.config, args.profile)
    encoded = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding='utf-8')
    print(encoded, end='')
    return 0 if report['config_gate'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
