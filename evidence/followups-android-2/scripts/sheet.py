import sys, json
from PIL import Image, ImageDraw
d, js, out, mi = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
ks=[int(k) for k in sys.argv[5].split(',')]
J=json.load(open(js)); rt={r[0]:r[1] for r in J['rows']}; t0=J['marks'][mi][1]
W=216;H=480;FH=40
im=Image.new('RGB',(W*len(ks),20+H+FH*2),'black'); dr=ImageDraw.Draw(im)
for i,k in enumerate(ks):
    f=Image.open('%s/%04d.png'%(d,k+1)).convert('RGB')
    im.paste(f.resize((W,H)),(i*W,20))
    im.paste(f.crop((380,2255,700,2315)).resize((W,FH*2)),(i*W,20+H))
    dr.text((i*W+4,4),f"f{k} {rt.get(k,t0)-t0:+.0f}ms",fill='yellow')
im.save(out)
