"""Bounded real-device software decode comparison; no display or sound changes."""
import argparse
import datetime
import hashlib
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from console_ssh import trusted_public_key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--playback', action='store_true', help='Play one 30-second 720p clip to the verified framebuffer and ALSA device')
    parser.add_argument('--handoff-helper', type=Path, help='Same-geometry framebuffer handoff helper for the stock bootloader logo')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    token = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    evidence = root / 'artifacts/hardware-validation' / token / 'software-media'
    evidence.mkdir(parents=True)
    stage = '/proc/1/root/tmp/mibox-media-' + token
    records = []
    proof = dict(physical=True, mode='playback' if args.playback else 'decode', software_decode={}, hardware_decode='NOT_TESTED',
                 HDMI='NOT_TESTED', audio='NOT_TESTED', stage=stage)

    def run(name, command, timeout=30, data=None):
        started = time.monotonic()
        utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
        try:
            result = subprocess.run(command, input=data, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            (evidence / (name + '.txt')).write_bytes((error.stdout or b'') + (error.stderr or b''))
            records.append(dict(name=name, started=utc, timeout=True, output_complete=False))
            raise
        (evidence / (name + '.txt')).write_bytes(result.stdout + result.stderr)
        records.append(dict(name=name, started=utc, seconds=time.monotonic()-started,
                            exit_code=result.returncode, output_complete=True))
        if result.returncode:
            raise RuntimeError(f'{name}: exit {result.returncode}; see retained output')
        return result.stdout.decode(errors='replace').replace('\r', '').strip()

    try:
        usb = [str(root / 'phone-tools/platform-tools/adb.exe'), '-s', '248243005297', 'shell']
        public = trusted_public_key(root, args.private_key, run)
        known = evidence / 'known_hosts'
        known.write_text('192.168.1.222 ' + ' '.join(public) + '\n')
        boot_id = run('usb-boot-id', usb + ['cat /proc/sys/kernel/random/boot_id'])
        proof['boot_id'] = boot_id
        with tempfile.TemporaryDirectory(prefix='mibox-media-key-') as directory:
            key = Path(directory) / 'key'
            shutil.copyfile(args.private_key, key)
            key.chmod(0o600)
            ssh = ['ssh', '-i', str(key), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
                   '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
                   '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5',
                   '-o', 'ServerAliveCountMax=3', 'root@192.168.1.222']
            if run('ssh-boot-id', ssh + ['cat /proc/sys/kernel/random/boot_id']) != boot_id:
                raise RuntimeError('USB/SSH identity mismatch')
            guard = ('set -eu; test -f /etc/mibox-persistent-root; '
                     'test "$(cat /proc/sys/kernel/osrelease)" = 3.10.33; '
                     'case "$(stat -f -c %t /proc/1/root/tmp)" in 1021994|858458f6) ;; *) exit 1;; esac; '
                     'test "$(awk \'/^MemFree:/ {print $2}\' /proc/meminfo)" -ge 262144; '
                     f'test ! -e {stage}; cat /proc/meminfo; stat -f /proc/1/root/tmp; mkdir -m 700 {stage}')
            run('ram-guard', ssh + [guard])
            try:
                archive = root / 'target/hardware-media/armv7-media-tools.tar.gz'
                manifest = json.loads((root / 'artifacts/hardware-validation/media-tools/manifest.json').read_text())
                proof['tool_archive_sha256'] = manifest['archive_sha256']
                if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['archive_sha256']:
                    raise RuntimeError('local tool archive changed')
                run('tools-upload', ssh + [f'umask 077; set -C; cat > {stage}/tools.tar.gz'], timeout=90, data=archive.read_bytes())
                actual = run('tools-hash', ssh + [f'sha256sum {stage}/tools.tar.gz']).split()[0]
                if actual != manifest['archive_sha256']:
                    raise RuntimeError('tool archive transfer mismatch')
                run('tools-extract', ssh + [f'tar -xzf {stage}/tools.tar.gz -C {stage} && rm {stage}/tools.tar.gz'], timeout=45)
                ffmpeg = f'{stage}/lib/ld-musl-armhf.so.1 --library-path {stage}/usr/lib/pulseaudio:{stage}/usr/lib:{stage}/lib {stage}/usr/bin/ffmpeg'
                run('physical-ffmpeg-version', ssh + [ffmpeg + ' -version'])
                fixtures = json.loads((root / 'artifacts/hardware-validation/media-fixtures/manifest.json').read_text())
                for fixture in fixtures['fixtures']:
                    name = fixture['name']
                    if args.playback and name != 'h264-720p30':
                        continue
                    clip = root / 'target/hardware-media' / (name + '.mp4')
                    if hashlib.sha256(clip.read_bytes()).hexdigest() != fixture['sha256']:
                        raise RuntimeError('fixture changed')
                    remote = stage + '/clip.mp4'
                    run(name + '-upload', ssh + [f'umask 077; set -C; cat > {remote}'], timeout=90, data=clip.read_bytes())
                    if run(name + '-hash', ssh + [f'sha256sum {remote}']).split()[0] != fixture['sha256']:
                        raise RuntimeError('fixture transfer mismatch')
                    if args.playback:
                        info = run('framebuffer-info', ssh + ['/bin/busybox fbset -s'])
                        if 'geometry 1280 1080 1280 3240 32' not in info or 'rgba 8/0,8/8,8/16,8/24' not in info:
                            raise RuntimeError('Framebuffer layout differs from the measured playback configuration')
                        if args.handoff_helper:
                            helper = args.handoff_helper.read_bytes()
                            digest = hashlib.sha256(helper).hexdigest()
                            run('handoff-upload', ssh + [f'umask 077; set -C; cat > {stage}/handoff'], data=helper)
                            if run('handoff-hash', ssh + [f'sha256sum {stage}/handoff']).split()[0] != digest:
                                raise RuntimeError('handoff helper transfer mismatch')
                            proof['handoff_helper_sha256'] = digest
                            run('framebuffer-handoff', ssh + [f'chmod 700 {stage}/handoff && {stage}/handoff'])
                        run('alsa-config', ssh + [f'cat > {stage}/alsa.conf'], data=b'pcm.test { type hw card 0 device 0 }\n')
                        command = (f'ALSA_CONFIG_PATH={stage}/alsa.conf timeout -s TERM -k 5 50 {ffmpeg} '
                                   '-nostdin -hide_banner -loglevel info -threads 2 -re '
                                   f'-i {remote} -map 0:v:0 -vf pad=1280:1080:0:180:black '
                                   '-pix_fmt rgba -f fbdev /dev/fb0 -map 0:a:0 -c:a pcm_s16le -ar 48000 -ac 2 -f alsa test')
                        (evidence / 'playback-started.json').write_text(json.dumps(dict(
                            started=datetime.datetime.now(datetime.timezone.utc).isoformat(), command=command), indent=2)+'\n')
                        run(name + '-playback', ssh + [command], timeout=65)
                        proof['playback_process'] = 'PASS'
                        proof['HDMI'] = 'OWNER_CONFIRMATION_PENDING'
                        proof['audio'] = 'OWNER_CONFIRMATION_PENDING'
                        run(name + '-remove', ssh + [f'rm {remote}'])
                        continue
                    output = run(name + '-decode', ssh + [f'timeout -s TERM -k 5 90 {ffmpeg} -hide_banner -loglevel error -threads 2 -i {remote} -map 0:v:0 -pix_fmt yuv420p -f framehash -hash sha256 -'], timeout=105)
                    def frames(text):
                        return [line.strip() for line in text.splitlines() if line.strip() and not line.startswith('#')]
                    expected = (root / 'artifacts/hardware-validation/media-fixtures' / (name + '.framehash')).read_text()
                    actual = frames(output)
                    matched = actual == frames(expected) and len(actual) == 900
                    proof['software_decode'][name] = dict(status='PASS' if matched else 'FAIL',
                                                          frames=len(actual), hashes_match=matched,
                                                          fixture_sha256=fixture['sha256'])
                    run(name + '-remove', ssh + [f'rm {remote}'])
                    if not matched:
                        raise RuntimeError('decoded frame reference mismatch')
                run('kernel-after', ssh + ['dmesg'])
                if run('boot-id-after', ssh + ['cat /proc/sys/kernel/random/boot_id']) != boot_id:
                    raise RuntimeError('boot changed during software decode')
            finally:
                run('ram-cleanup', ssh + [f'rm -rf {stage}; test ! -e {stage}; cat /proc/meminfo'], timeout=30)
                proof['temporary_files_removed'] = True
    except Exception as error:
        proof['failure'] = str(error)
        raise
    finally:
        (evidence / 'commands.json').write_text(json.dumps(records, indent=2) + '\n')
        (evidence / 'result.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(json.dumps(proof, indent=2))


if __name__ == '__main__':
    main()
