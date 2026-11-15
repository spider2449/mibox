"""WSL: deploy fixed updater in RAM and check/install/remove its exact payload."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--action', choices=['check','install','remove','recover-original'], default='check')
    args=parser.parse_args()
    stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    evidence=ROOT/'artifacts/restoration/2026-11-15'/('window-'+args.action+'-'+stamp)
    evidence.mkdir(parents=True)
    proof=dict(action=args.action, device_access=True, write_attempted=False, full_readback_match=False)
    records=[]

    def run(label, command, content=None, timeout=30):
        result=subprocess.run(command,input=content,capture_output=True,timeout=timeout)
        (evidence/(label+'.stdout')).write_bytes(result.stdout)
        (evidence/(label+'.stderr')).write_bytes(result.stderr)
        records.append(dict(label=label,exit_code=result.returncode,stdout_complete=True,stderr_complete=True))
        if result.returncode:
            raise RuntimeError(label+': exit '+str(result.returncode))
        return result.stdout.decode().replace('\r','').strip()

    try:
        adb=[str(ROOT/'phone-tools/platform-tools/adb.exe'),'-s','248243005297','shell']
        if 'ID=mibox-custom' not in run('usb-os',adb+['cat /etc/os-release']).splitlines():
            raise ValueError('custom RAM OS required')
        boot=run('usb-boot',adb+['cat /proc/sys/kernel/random/boot_id'])
        if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',boot):
            raise ValueError('invalid boot UUID')
        public=run('usb-key',adb+['cat /etc/dropbear/dropbear_ed25519_host_key.pub']).split()
        if len(public)<2 or public[0]!='ssh-ed25519':
            raise ValueError('USB-authenticated host key missing')
        known=evidence/'known_hosts'
        known.write_text('192.168.1.222 '+' '.join(public[:2])+'\n')
        manifest=json.loads((ROOT/'artifacts/restoration/2026-11-15/rescue-env-build.json').read_text())
        executable=(ROOT/'target/rescue-window/rescue-env').read_bytes()
        digest=hashlib.sha256(executable).hexdigest()
        if digest!=manifest['binary_sha256']:
            raise ValueError('updater differs from build manifest')
        if hashlib.sha256((ROOT/'src/hardware/rescue-env.c').read_bytes()).hexdigest()!=manifest['source_sha256']:
            raise ValueError('updater source changed since build')
        if args.action!='check':
            tests=json.loads((ROOT/'artifacts/restoration/2026-11-15/rescue-env-host-tests.json').read_text())
            if (tests.get('passed') is not True or tests.get('tests')!=10
                    or tests.get('updater_source_sha256')!=manifest['source_sha256']):
                raise ValueError('host updater tests required')
        if args.action=='install':
            # A raw backup must already be on the host, independently hashed on
            # the same running boot; do not rely solely on embedded defaults.
            backups=[]
            for report in (ROOT/'artifacts/restoration/2026-11-15').glob('environment-*/result.json'):
                saved=json.loads(report.read_text())
                if (saved.get('backup_verified') is True and saved.get('boot_id')==boot
                        and saved.get('sha256')==tests['source_sha256']):
                    destination=Path(saved['backup'])
                    if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest()==saved['sha256']:
                        backups.append(str(report))
            if not backups:
                raise ValueError('same-boot complete device-hashed original backup required')
            proof['original_backup_evidence']=backups
        with tempfile.TemporaryDirectory(prefix='mibox-rescue-key-') as name:
            key=Path(name)/'key'
            shutil.copyfile('/mnt/c/Users/morefunfun/.ssh/mibox-console',key)
            key.chmod(0o600)
            ssh=['ssh','-i',str(key),'-o','BatchMode=yes','-o','IdentitiesOnly=yes',
                 '-o','StrictHostKeyChecking=yes','-o',f'UserKnownHostsFile={known}',
                 '-o','ConnectTimeout=8','root@192.168.1.222']
            path='/proc/1/root/tmp/mibox-rescue-env-'+stamp
            verified=run('ram-tool-upload',ssh+['test ! -e '+path+' && cat > '+path+
                         ' && busybox chmod 700 '+path+' && sha256sum '+path],executable)
            if verified.split()[0]!=digest:
                raise ValueError('uploaded updater hash mismatch')
            identity=run('ssh-boot',ssh+['cat /proc/sys/kernel/random/boot_id'])
            if identity!=boot:
                raise ValueError('USB/SSH boot UUID mismatch')
            if args.action=='install':
                checked=run('device-check',ssh+[path+' --check'])
                if checked!='MIBOX_ENV_CHECK_OK original_exact=1 bytes=4194304':
                    raise ValueError('device check response mismatch')
            proof.update(boot_id=boot,updater_sha256=digest,ram_tool=path)
            proof['write_attempted']=args.action!='check'
            output=run('device-'+args.action,ssh+[path+' --'+args.action])
            expected={'check':'MIBOX_ENV_CHECK_OK original_exact=1 bytes=4194304',
                      'install':'MIBOX_ENV_INSTALLED full_readback_match=1',
                      'remove':'MIBOX_ENV_REMOVED full_readback_match=1',
                      'recover-original':'MIBOX_ENV_REMOVED full_readback_match=1'}[args.action]
            if output!=expected:
                raise ValueError('unexpected updater result')
            proof['full_readback_match']=args.action!='check'
            proof['check_passed']=True
            proof['runtime_boot_unchanged']=run('post-boot',ssh+['cat /proc/sys/kernel/random/boot_id'])==boot
            if not proof['runtime_boot_unchanged']:
                raise ValueError('boot identity changed')
            # Retain the exact recovery executable in RAM after a write. It can
            # remove the installed setting before any reboot if needed.
            if args.action=='check':
                run('ram-tool-cleanup',ssh+['rm -f '+path])
        print(json.dumps(proof,indent=2))
    except Exception as error:
        proof['failure']=str(error)
        raise
    finally:
        proof['commands']=records
        (evidence/'result.json').write_text(json.dumps(proof,indent=2)+'\n')


if __name__=='__main__':
    main()
