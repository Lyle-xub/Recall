# SSIM: RGB channels, 11x11 uniform window, reflected edges, population covariance, L=255, K1=.01, K2=.03.
# Interior excludes 8 px boundaries and text; rim is the inner 3 px boundary.
# Fixed masks derive from MaterialReferenceView/MaterialReference.swift; no registration or fitted transforms.
from pathlib import Path
from PIL import Image,ImageDraw
import numpy as np,json,argparse
parser=argparse.ArgumentParser(description="Compare separately masked material regions; this is not a whole-app fidelity score. Requires Pillow and NumPy.")
parser.add_argument("directory",type=Path)
parser.add_argument("--round",default="glass")
args=parser.parse_args()
ref=Path(__file__).resolve().parents[1]/'docs/macos-visual-reference/native-glass/srgb'; cap=args.directory
w,h=1280,800
surfaces=[(130,24,620,64,32),(40,132,140,52,26),(400,708,480,54,27)]+[(766+i*80,24,64,64,32) for i in range(5)]+[(x,224,360,380,29) for x in (40,460,880)]
def mask(inset):
 im=Image.new('1',(w,h));d=ImageDraw.Draw(im)
 for x,y,cw,ch,r in surfaces:d.rounded_rectangle((x+inset,y+inset,x+cw-inset-1,y+ch-inset-1),max(0,r-inset),fill=1)
 return np.array(im,dtype=bool)
allm=mask(0);inside=mask(8);rim=allm&~mask(3)
textmask=Image.new('1',(w,h));d=ImageDraw.Draw(textmask)
for rect in [(350,37,535,74),(70,141,149,174),(470,720,815,752)]+[(x+16,40,x+48,73) for x in (766,846,926,1006,1086)]:d.rectangle(rect,fill=1)
txt=np.array(textmask,dtype=bool);inside &= ~txt
masks={'interior':inside,'rim':rim,'text_and_icons':txt,'background':~allm}
def mean(a,r=5):
 a=np.pad(a,((r,r),(r,r),(0,0)),mode='reflect');a=np.pad(a,((1,0),(1,0),(0,0)))
 a=a.cumsum(0).cumsum(1);k=2*r+1
 return (a[k:,k:]-a[:-k,k:]-a[k:,:-k]+a[:-k,:-k])/(k*k)
def scores(a,b):
 ma,mb=mean(a),mean(b);va=mean(a*a)-ma*ma;vb=mean(b*b)-mb*mb;cov=mean(a*b)-ma*mb
 s=((2*ma*mb+6.5025)*(2*cov+58.5225))/((ma*ma+mb*mb+6.5025)*(va+vb+58.5225))
 return {k:{'rgb_mae':round(float(abs(a-b)[m].mean()),3),'ssim':round(float(s[m].mean()),4)} for k,m in masks.items()}
round_name=args.round;out={}
for kind in ['material','background']:
 for theme in ['light','dark']:
  a=np.asarray(Image.open(ref/f'mac-{kind}-{theme}.png').convert('RGB'),dtype=float)
  b=np.asarray(Image.open(cap/f'{round_name}-{kind}-{theme}/000.png').convert('RGB'),dtype=float)
  if a.shape != (800,1280,3) or b.shape != a.shape: raise ValueError('Capture at 1280x800 and 100% scale before comparing.')
  out[f'{kind}-{theme}']=scores(a,b)
print(json.dumps(out,indent=2));(cap/f'{round_name}-comparison.json').write_text(json.dumps(out,indent=2))
