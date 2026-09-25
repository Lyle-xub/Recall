"""Original, deterministic ambient opening; no external samples or recordings.

Slow harmonic swells follow the glass, halo, name and white reveal. A diffuse
stereo tail replaces struck bells so the short cue feels suspended and airy.
"""
import array
import math
from pathlib import Path
import random
import sys
import wave

rate, duration = 44100, 7.2
rng = random.Random(250925)
left, right = [], []
low, slow = 0.0, 0.0

def swell(t, start, frequency, amplitude, pan, attack, decay):
    u = t - start
    if u <= 0:
        return 0.0, 0.0
    envelope = (1-math.exp(-u/attack)) ** 2 * math.exp(-u/decay)
    shimmer = .94 + .06*math.sin(math.tau*.31*u)
    channels = []
    for detune, balance in ((.9997, (1-pan)/2), (1.0003, (1+pan)/2)):
        phase = math.tau*frequency*detune*u + .025*math.sin(math.tau*.23*u)
        # Pure, gently detuned overtones: no metallic/inharmonic bell attack.
        value = math.sin(phase) + .10*math.sin(2*phase) + .018*math.sin(3*phase)
        channels.append(value*envelope*shimmer*amplitude*math.sqrt(balance))
    return channels

for index in range(int(rate * duration)):
    t = index / rate
    noise = rng.uniform(-1, 1)
    low += 0.10 * (noise-low)
    slow += 0.016 * (noise-slow)
    breath = max(0, math.sin(math.pi * min(1, t/6.2))) ** 2
    air = (low-slow) * breath * .009
    l = air * (.8 + .15*math.sin(t*1.8))
    r = air * (.8 - .15*math.sin(t*1.8))
    for start, freq, amplitude, pan, attack, decay in (
        (.05, 329.628, .035, -.10, .65, 3.0),
        (.75, 659.255, .12, -.24, .65, 3.4),
        (1.38, 987.767, .055, .25, .75, 3.0),
        (2.05, 1479.978, .034, -.30, .75, 2.6),
        (2.80, 1318.510, .027, .32, .78, 2.6),
        (4.08, 493.883, .025, .12, .65, 1.8),
        (4.28, 659.255, .032, -.10, .72, 1.9),
    ):
        a, b = swell(t, start, freq, amplitude, pan, attack, decay)
        l += a;r += b
    left.append(l);right.append(r)

# Uneven, low-pass reflections form a wide continuous space, not rhythmic echoes.
source_l, source_r = left[:], right[:]
for tap, delay in enumerate((.071,.113,.173,.239,.317,.409,.521,.647,.797,.971,1.163,1.379)):
    gain = .12*math.exp(-delay/1.15)
    offset = int(delay*rate)
    reflected_l = reflected_r = 0.0
    for i in range(offset,len(left)):
        a, b = source_l[i-offset], source_r[i-offset]
        if tap % 2 == 0:
            a, b = b, a
        reflected_l += .20*(a-reflected_l)
        reflected_r += .20*(b-reflected_r)
        left[i] += reflected_l*gain
        right[i] += reflected_r*gain

# Raised-cosine fades have zero slope at both ends; the tail dissolves into silence.
for i in range(len(left)):
    t = i/rate
    fade_in = .5-.5*math.cos(math.pi*min(1,t/.18))
    remaining = (len(left)-1-i)/rate
    fade_out = .5-.5*math.cos(math.pi*min(1,remaining/1.35))
    left[i] *= fade_in*fade_out
    right[i] *= fade_in*fade_out
peak = max(max(map(abs,left)),max(map(abs,right)))
pcm = array.array('h')
for i, (l,r) in enumerate(zip(left,right)):
    for value in (l,r):
        pcm.append(round(value/peak*10**(-9/20)*32767))
if sys.byteorder != 'little':
    pcm.byteswap()
output = Path(__file__).resolve().parents[2]/'macOS/Artwork/Recall-Opening.wav'
with wave.open(str(output),'wb') as audio:
    audio.setnchannels(2);audio.setsampwidth(2);audio.setframerate(rate);audio.writeframes(pcm.tobytes())
print(f'{output.name}: {duration:.1f}s, stereo {rate} Hz, peak -9.0 dBFS, silent endpoints')
