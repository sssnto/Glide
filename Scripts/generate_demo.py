from PIL import Image, ImageDraw
import math, subprocess
from pathlib import Path
out=Path(__file__).resolve().parents[1] / 'Glide/Resources'
W,H=480,854
palettes=[((24,68,76),(191,207,164)),((123,67,79),(245,180,118)),((16,32,72),(143,168,180))]
for idx,(top,bottom) in enumerate(palettes):
 bg=Image.new('RGB',(W,H)); d=ImageDraw.Draw(bg)
 for y in range(H):
  t=y/H; d.line((0,y,W,y),fill=tuple(int(a*(1-t)+b*t) for a,b in zip(top,bottom)))
 p=subprocess.Popen(['ffmpeg','-y','-loglevel','error','-f','rawvideo','-vcodec','rawvideo','-s',f'{W}x{H}','-pix_fmt','rgb24','-r','24','-i','-','-an','-c:v','libx264','-preset','fast','-crf','24','-pix_fmt','yuv420p','-movflags','+faststart',str(out/f'demo{idx}.mp4')],stdin=subprocess.PIPE)
 for frame in range(288):
  t=frame/288*math.tau; image=bg.copy(); draw=ImageDraw.Draw(image)
  x=W*.7+math.sin(t)*5; y=H*.29+math.cos(t)*3; r=43
  draw.ellipse((x-r,y-r,x+r,y+r),fill=(246,229,185) if idx!=2 else (204,221,232))
  for layer in range(4):
   points=[(0,H)]
   for step in range(W+1):
    v=step/W
    wave=math.sin(v*6+layer*1.5+math.sin(t)*.025*(4-layer))*.10+math.sin(v*13+layer)*.035
    points.append((step,H*(.50+layer*.115+wave)))
   points += [(W,H)]
   depth=.5+layer*.13
   base=(7+idx*5,33+idx*3,39+idx*8)
   color=tuple(int(b*(1-depth)+a*depth) for a,b in zip(base,bottom))
   draw.polygon(points,fill=color)
  p.stdin.write(image.tobytes())
 p.stdin.close(); assert p.wait()==0
 print('Generated demo',idx)
