"""Package native saved-result screenshots into a labeled research walkthrough.

Requires Pillow and imageio-ffmpeg. Input: folders inspect/compare/probe/sae,
each containing window-lab-dark.png from Dyno --snapshot --lab-only.
No inference or synthetic measurement generation occurs here.
"""
import argparse
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw, ImageFont
import imageio_ffmpeg

parser = argparse.ArgumentParser()
parser.add_argument('input', type=Path)
parser.add_argument('--output', type=Path, default=Path('docs/assets'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
font = '/System/Library/Fonts/Supplemental/Arial.ttf'
title_font = ImageFont.truetype(font, 32)
label_font = ImageFont.truetype(font, 20)
steps = [('inspect', '01  Observe activations and next-token predictions'),
         ('compare', '02  Intervene and compare with the baseline'),
         ('probe', '03  Test a labeled probe on held-out examples'),
         ('sae', '04  Explore sparse features and reconstruction')]
frames = []
for method, title in steps:
    source = Image.open(args.input / method / 'window-lab-dark.png').convert('RGB')
    # Crop to the native result panel; exclude machine identity and private history.
    panel = source.crop((860, 360, 2390, 1640))
    panel.thumbnail((1160, 954), Image.Resampling.LANCZOS)
    frame = Image.new('RGB', (1280, 1120), '#101117')
    draw = ImageDraw.Draw(frame)
    draw.text((40, 20), 'DYNO / AI RESEARCH LAB / 0.2.0', font=label_font, fill='#a794fa')
    draw.text((40, 55), title, font=title_font, fill='white')
    frame.paste(panel, ((1280-panel.width)//2, 112))
    draw.text((40, 1080), 'Recorded results • Qwen 0.5B • Small demonstrations, not safety evaluations', font=label_font, fill='#b7b9c8')
    frame.save(args.output / f'research-{method}.png', optimize=True)
    frames.append(frame)
frames[0].save(args.output / 'research-walkthrough.gif', save_all=True,
               append_images=frames[1:], duration=5000, loop=0, optimize=True)
listing = args.input / 'frames.txt'
listing.write_text(''.join(f"file '{(args.output / ('research-'+m+'.png')).resolve()}'\nduration 5\n" for m,_ in steps)+f"file '{(args.output / 'research-sae.png').resolve()}'\n")
subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), '-y', '-f', 'concat', '-safe', '0',
    '-i', str(listing), '-vf', 'fps=24,format=yuv420p', '-c:v', 'libx264', '-crf', '20',
    '-movflags', '+faststart', str(args.output/'research-walkthrough.mp4')], check=True,
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
