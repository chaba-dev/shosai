# pull.sh PREFIX N  -> pulls frames + builds bottom strip sheet
P=$1; N=$2
for i in $(seq 1 $N); do adb pull /data/local/tmp/${P}_$i.png $S/r4/ev/${P}_$i.png >/dev/null; done
adb shell "rm -f /data/local/tmp/${P}_*.png"
python3 - "$P" "$N" <<PY
import sys
from PIL import Image, ImageDraw
P,N=sys.argv[1],int(sys.argv[2])
t=dict(l.split() for l in open('$S/r4/'+P+'_times.txt'))
cols=8; rows=(N+cols-1)//cols
s=Image.new('RGB',(240*cols,rows*(20+100+60)),'black'); d=ImageDraw.Draw(s)
for k in range(1,N+1):
    im=Image.open('$S/r4/ev/%s_%d.png'%(P,k)).convert('RGB')
    x=((k-1)%cols)*240; y=((k-1)//cols)*180
    d.text((x+4,y+4),'#%d +%sms'%(k,t[str(k)]),fill='yellow')
    s.paste(im.crop((0,130,1080,580)).resize((240,100)),(x,y+20))
    s.paste(im.crop((300,2225,780,2330)).resize((240,53)),(x,y+122))
s.save('$S/r4/'+P+'.png')
PY
