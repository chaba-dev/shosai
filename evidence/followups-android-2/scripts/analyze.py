import sys, struct, subprocess, numpy as np, json
src, marksf = sys.argv[1], sys.argv[2]
regions = json.loads(sys.argv[3])
thr = float(sys.argv[4]) if len(sys.argv)>4 else 1.0
d=open(src,'rb').read()
i=d.find(b'#VV1NSC0PET1ME2#')
ver=struct.unpack('<I',d[i+16:i+20])[0]; off=struct.unpack('<q',d[i+20:i+28])[0]; n=struct.unpack('<I',d[i+28:i+32])[0]
ts=struct.unpack('<%dQ'%n,d[i+32:i+32+8*n])
rt=[(t+off)/1e6 for t in ts]   # realtime ms
marks=[(l.split()[0],int(l.split()[1])/1e6) for l in open(marksf) if l.strip()]
W,H=1080,2400
p=subprocess.Popen(['ffmpeg','-v','quiet','-i',src,'-vsync','0','-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE)
prev=None; k=0; rows=[]
while True:
    b=p.stdout.read(W*H*3)
    if len(b)<W*H*3: break
    f=np.frombuffer(b,np.uint8).reshape(H,W,3).astype(np.int16)
    if prev is not None:
        rows.append((k,rt[k],{nm:float(np.abs(f[y0:y1,x0:x1]-prev[y0:y1,x0:x1]).mean()) for nm,(x0,y0,x1,y1) in regions.items()}))
    prev=f; k+=1
print('frames',k,'meta',n)
t0=marks[0][1]
evs=[]
for idx,(nm,t) in enumerate(marks):
    if nm=='pre': continue
    pre=marks[idx-1][1]; nxt=marks[idx+1][1] if idx+1<len(marks) else 1e18
    first={}
    for (fk,ft,dd) in rows:
        if ft<pre or ft>=nxt: continue
        for r,v in dd.items():
            if v>thr and r not in first: first[r]=(fk,ft)
    print(f"{nm:7s} pre={pre-t0:8.1f} post={t-t0:8.1f} | "+"  ".join(f"{r}: f{fk} +{ft-t:6.1f}ms (from pre +{ft-pre:6.1f})" for r,(fk,ft) in sorted(first.items(), key=lambda kv: kv[1][1])))
    evs.append((nm,pre,t,first))
json.dump({'rows':[(a,b,c) for a,b,c in rows],'marks':marks},open(src+'.json','w'))
