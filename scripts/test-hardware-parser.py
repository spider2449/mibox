"""Host ASan/UBSan tests for the DHCP parser; never opens a device or network."""
import hashlib
import argparse
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence',type=Path,default=root/'artifacts/network-hdmi-audio/hardware-candidate')
args=parser.parse_args()
binary = root / 'target/hardware-helper/parser-asan'
binary.parent.mkdir(parents=True, exist_ok=True)
command = ['gcc', '-fsanitize=address,undefined', '-g', '-Wall', '-Wextra', '-Werror',
           '-Wno-misleading-indentation', '-o', str(binary), str(root / 'src/hardware/test-parser.c'), '-lm']
subprocess.run(command, check=True, timeout=30)
result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
evidence = args.evidence
evidence.mkdir(parents=True, exist_ok=True)
report = dict(scope='Host parser only; no physical network validation', command=command,
              exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr,
              source_sha256=hashlib.sha256((root / 'src/hardware/mibox-hardware.c').read_bytes()).hexdigest(),
              test_sha256=hashlib.sha256((root / 'src/hardware/test-parser.c').read_bytes()).hexdigest())
(evidence / 'parser-sanitizers.json').write_text(json.dumps(report, indent=2) + '\n')
print(result.stdout, end='')
if result.returncode:
    raise SystemExit(result.stderr or result.returncode)
