"""Add synthetic video fixtures to an existing visual-parity directory.

Run before launching validation to create video.png. The app encodes its 20 s
MP4 on first launch. Close that instance and run this script again to create
quarter-turn metadata and invalid-media fixtures, then restart validation.
Requires Pillow. Never reads the user's library.
"""
from pathlib import Path
import argparse
import struct
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
args = parser.parse_args()
fixtures = args.directory / 'fixtures'
if not (fixtures / 'fixture.json').is_file():
    raise SystemExit('An existing synthetic visual-parity fixture directory is required.')
im = Image.new('RGB', (1280, 720), '#152338')
draw = ImageDraw.Draw(im)
font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 48)
for xy, color, label in [((0,0), '#ef4444', 'TL'), ((1080,0), '#22c55e', 'TR'), ((0,590), '#3b82f6', 'BL'), ((1080,590), '#eac63b', 'BR')]:
    x,y = xy
    draw.rectangle((x,y,x+200,y+130), fill=color)
    draw.text((x+25,y+25), label, font=font, fill='white')
draw.text((260,55), 'TOP — upright video', font=font, fill='white')
draw.polygon([(640,170),(570,270),(610,270),(610,305),(670,305),(670,270),(710,270)], fill='white')
draw.text((300,340), 'Recall video validation', font=font, fill='white')
draw.text((370,605), 'BOTTOM — 16:9', font=font, fill='white')
im.save(fixtures / 'video.png')
original = args.directory / 'library/recordings/parity-video.mp4'
if original.is_file():
    data = bytearray(original.read_bytes())
    def rotate_tracks(start, end):
        p = start
        while p + 8 <= end:
            size, kind = struct.unpack_from('>I4s', data, p)
            if size < 8 or p + size > end:
                break
            if kind == b'tkhd':
                offset = p + 8 + (52 if data[p+8] == 1 else 40)
                width, height = struct.unpack_from('>II', data, offset+36)
                if width and height:
                    struct.pack_into('>9i', data, offset, 0,65536,0,-65536,0,0,height,0,1073741824)
            if kind in (b'moov', b'trak'):
                rotate_tracks(p+8, p+size)
            p += size
    rotate_tracks(0, len(data))
    (fixtures / 'video-rotated.mp4').write_bytes(data)
    (fixtures / 'video-broken.mp4').write_bytes(b'Recall intentionally invalid synthetic media')
    print('Prepared upright image, rotated metadata and invalid-media fixtures.')
else:
    print('Image ready. Launch validation once to encode the synthetic MP4, then rerun.')
