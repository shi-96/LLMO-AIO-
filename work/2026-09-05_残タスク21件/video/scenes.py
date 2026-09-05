from PIL import Image, ImageDraw, ImageFont
JP="/etc/alternatives/fonts-japanese-gothic.ttf"
W,H=1080,1920
def F(s): return ImageFont.truetype(JP,s)

def grad(c1,c2):
    im=Image.new("RGB",(W,H))
    d=ImageDraw.Draw(im)
    for y in range(H):
        t=y/H
        d.line([(0,y),(W,y)],fill=tuple(int(c1[i]+(c2[i]-c1[i])*t) for i in range(3)))
    return im

def center(d,txt,y,font,fill,shadow=True):
    bb=d.textbbox((0,0),txt,font=font); w=bb[2]-bb[0]
    x=(W-w)//2
    if shadow: d.text((x+4,y+4),txt,font=font,fill=(0,0,0,120))
    d.text((x,y),txt,font=font,fill=fill)

scenes=[
 (( 18, 22, 40),( 44, 32, 78),"01","AI秘書の15秒",["朝いちの30分で","その日の段取りが決まる"]),
 (( 20, 34, 46),( 16, 62, 74),"02","調べる",["12件の調査カードを","一次情報で裏取り"]),
 (( 42, 26, 24),( 82, 46, 26),"03","作る",["粗編集も字幕焼き込みも","コマンドだけで完結"]),
 (( 16, 30, 26),( 22, 70, 52),"04","残す",["결果はドライブへ","URLひとつで確認"]),
]
scenes[3]=((16,30,26),(22,70,52),"04","残す",["結果はドライブへ","URLひとつで確認"])

for i,(c1,c2,num,title,lines) in enumerate(scenes):
    im=grad(c1,c2); d=ImageDraw.Draw(im,"RGBA")
    # accent bar
    d.rectangle([0,0,W,14],fill=(240,190,90))
    d.text((80,180),num,font=F(120),fill=(240,190,90))
    d.line([(80,340),(280,340)],fill=(240,190,90),width=8)
    center(d,title,H//2-320,F(160),(255,255,255))
    y=H//2-40
    for ln in lines:
        center(d,ln,y,F(72),(226,232,240)); y+=120
    d.text((80,H-140),"2026-09-05  自動生成テスト",font=F(40),fill=(255,255,255,150))
    im.save(f"s{i}.png")
print("scenes ok")
