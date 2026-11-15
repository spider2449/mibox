"""Bootstrap public host-key readability, then authenticate it over USB ADB."""
import shutil
import tempfile
from pathlib import Path


def trusted_public_key(root, private_key, run):
    usb = [str(root / 'phone-tools/platform-tools/adb.exe'), '-s', '248243005297', 'shell']
    path = '/etc/dropbear/dropbear_ed25519_host_key.pub'
    public = run('usb-host-key', usb + ['cat ' + path]).split()
    if len(public) >= 2 and public[0] == 'ssh-ed25519':
        return public[:2]
    # The release's dropbearkey creates its *public* file with mode 0600.
    # A preliminary SSH connection performs ONLY chmod on that public file.
    # Do not trust network identity for mounting storage or installing anything:
    # require the subsequently USB-read public key to match the scanned key.
    scan = run('bootstrap-keyscan', ['ssh-keyscan', '-T', '10', '-t', 'ed25519', '192.168.1.222'], 20)
    keys = [line.split()[1:3] for line in scan.splitlines()
            if len(line.split()) >= 3 and line.split()[1] == 'ssh-ed25519']
    if len(keys) != 1:
        raise RuntimeError('exactly one Ed25519 server key required')
    with tempfile.TemporaryDirectory(prefix='mibox-public-key-') as directory:
        work = Path(directory)
        key = work / 'owner-key'
        shutil.copyfile(private_key, key)
        key.chmod(0o600)
        known = work / 'known_hosts'
        known.write_text('192.168.1.222 ' + ' '.join(keys[0]) + '\n')
        run('bootstrap-public-key-permission', ['ssh', '-i', str(key), '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', f'UserKnownHostsFile={known}', '-o', 'ConnectTimeout=10',
            'root@192.168.1.222', 'chmod 644 ' + path], 30)
    public = run('usb-host-key-after-bootstrap', usb + ['cat ' + path]).split()
    if len(public) < 2 or public[:2] != keys[0]:
        raise RuntimeError('SSH host key does not match the authenticated USB public key')
    return public[:2]
