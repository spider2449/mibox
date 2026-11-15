"""Generate short numbered H.264/AAC fixtures and host decode references in WSL."""
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
work = root / 'target/hardware-media'
evidence = root / 'artifacts/hardware-validation/media-fixtures'
work.mkdir(parents=True, exist_ok=True)
evidence.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0]
report = dict(generator=version, physical_playback='NOT_TESTED', fixtures=[])
for width, height, level in [(1280, 720, '3.1'), (1920, 1080, '4.0')]:
    name = f'h264-{height}p30'
    path = work / (name + '.mp4')
    tone = r'if(lt(mod(t\,1)\,0.1)\,0.06*sin(2*PI*1000*t)\,0)'
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
               '-f', 'lavfi', '-i', f'testsrc2=size={width}x{height}:rate=30',
               '-f', 'lavfi', '-i', f'aevalsrc={tone}|{tone}:s=48000:c=stereo',
               '-vf', "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:text='%{n}':x=40:y=40:fontsize=48:fontcolor=white:box=1:boxcolor=black,drawbox=x=0:y=0:w=100:h=100:color=white:t=fill:enable='lt(mod(t,1),0.1)'",
               '-t', '30', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '28',
               '-profile:v', 'main', '-level:v', level, '-pix_fmt', 'yuv420p', '-threads', '2',
               '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', str(path)]
    subprocess.run(command, check=True, timeout=180)
    probe = subprocess.check_output(['ffprobe', '-v', 'error', '-show_format', '-show_streams',
                                     '-of', 'json', str(path)], text=True)
    (evidence / (name + '.probe.json')).write_text(probe)
    decode = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', str(path),
              '-map', '0:v:0', '-pix_fmt', 'yuv420p', '-f', 'framehash', '-hash', 'sha256', '-']
    reference = subprocess.check_output(decode, text=True, timeout=120)
    (evidence / (name + '.framehash')).write_text(reference)
    frames = len([line for line in reference.splitlines() if line and not line.startswith('#')])
    if frames != 900:
        raise RuntimeError(f'{name}: expected 900 frames, found {frames}')
    report['fixtures'].append(dict(name=name, path=str(path), bytes=path.stat().st_size,
        sha256=hashlib.sha256(path.read_bytes()).hexdigest(), generation_command=command,
        host_decode_command=decode, host_frames=frames, duration_seconds=30,
        audio='48 kHz stereo AAC, gated 1 kHz tone at low amplitude',
        sync_pattern='100 ms white square and tone at each integer second'))
(evidence / 'manifest.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
