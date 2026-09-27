"""Run after test-windows-desktop-blur.ps1. Requires Pillow and NumPy.

Checks desktop color retention, attenuation of 2 px lines, and live host
sampling without rebuilding the Recall material. Not a macOS parity score.
"""
from pathlib import Path
import argparse
import json
import numpy as np
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path)
args = parser.parse_args()

def measure(name):
    path = args.directory / name
    pixels = np.asarray(Image.open(path / '000.png').convert('RGB'), dtype=float)
    if pixels.shape != (800, 1280, 3):
        raise ValueError('Use a 1280x800 desktop at 100% scale.')
    metrics = json.loads((path / 'metrics.json').read_text(encoding='utf-8'))
    assert not metrics['state']['backdrop']['usingFallback'], name
    assert metrics['state']['glass']['effectsAvailable'], name
    # The large reference cards now have their own desktop material. Measure
    # the shared background in the gap above those cards, not through a lens.
    band = pixels[190:220, 180:260].mean(1)
    left = band.mean(0)
    right = pixels[190:220, 590:670].mean((0, 1))
    y = np.arange(len(band))
    # Remove the broad Gaussian falloff from the scene's top edge, preserving
    # the high-frequency 2 px stripe signal this check is intended to detect.
    smooth = np.column_stack([np.polyval(np.polyfit(y, band[:,c], 2), y) for c in range(3)])
    return {'left_rgb': left.tolist(), 'color_separation': float(abs(left - right).mean()),
            'line_variation': float((band-smooth).std(0).max()),
            'control_line_variation': float(pixels[350:550,180:260].mean(1).std(0).max())}

results = {name: measure(name) for name in ['desktop-old-light', 'desktop-fixed-light',
                                          'desktop-live-change', 'desktop-fixed-dark']}
before, after = results['desktop-old-light'], results['desktop-fixed-light']
assert after['color_separation'] > max(35, before['color_separation'] * 4), 'Desktop washed out'
assert results['desktop-fixed-dark']['color_separation'] > 35, 'Dark desktop washed out'
assert after['line_variation'] < 3, 'Fine desktop lines remained sharp'
assert after['control_line_variation'] < 3, 'Fine lines remained sharp inside the controls'
delta = float(abs(np.array(after['left_rgb']) - results['desktop-live-change']['left_rgb']).mean())
assert delta > 35, 'Host backdrop did not follow the independent background change'
results['live_change_rgb_mae'] = delta
results['passed'] = True
text = json.dumps(results, indent=2)
(args.directory / 'desktop-blur-checks.json').write_text(text + '\n', encoding='utf-8')
print(text)
