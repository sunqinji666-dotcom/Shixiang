from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.utils import ImageReader

ROOT = Path(__file__).resolve().parent
SOCIAL = ROOT / 'social'
OUT = ROOT / 'output'
SHOT = ROOT / 'screenshots' / 'library.png'
ICON = ROOT / 'assets' / 'shixiang-icon.png'
SOCIAL.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)

FONT = '/System/Library/Fonts/STHeiti Light.ttc'
pdfmetrics.registerFont(TTFont('Heiti', FONT))

W = H = 1600
BG = '#0C0A12'; PANEL = '#171321'; PURPLE = '#7867FF'; GOLD = '#E6BD70'; WHITE = '#F5F2F8'; MUTED = '#ACA6B7'

def font(size): return ImageFont.truetype(FONT, size)
def pfont(size): return ImageFont.truetype(FONT, size)

def rounded(draw, box, fill, r=36, outline=None, width=1):
    draw.rounded_rectangle(box, r, fill=fill, outline=outline, width=width)

def wave(draw, x0, y, width, amp=56, color=(120,103,255,150), bars=58):
    step = width / bars
    for i in range(bars):
        f = ((i * 17) % 19) / 18
        a = amp * (.18 + .82 * f)
        x = x0 + i * step
        draw.rounded_rectangle((x, y-a, x+step*.42, y+a), 5, fill=color)

def base():
    im = Image.new('RGBA', (W,H), BG)
    glow = Image.new('RGBA', (W,H), (0,0,0,0)); gd = ImageDraw.Draw(glow)
    gd.ellipse((-380, -350, 1250, 950), fill=(91,70,210,78))
    gd.ellipse((700, 860, 1900, 1800), fill=(229,178,85,30))
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    return Image.alpha_composite(im, glow)

def text(draw, xy, s, size, fill=WHITE, anchor=None):
    return draw.text(xy, s, font=font(size), fill=fill, anchor=anchor)

def paste_shot(im, box, crop='full'):
    src = Image.open(SHOT).convert('RGB')
    if crop == 'center': src = src.crop((130, 40, src.width-25, src.height-35))
    target_w, target_h = box[2]-box[0], box[3]-box[1]
    ratio=max(target_w/src.width,target_h/src.height)
    src=src.resize((int(src.width*ratio),int(src.height*ratio)), Image.Resampling.LANCZOS)
    l=(src.width-target_w)//2; t=(src.height-target_h)//2
    src=src.crop((l,t,l+target_w,t+target_h))
    mask=Image.new('L',(target_w,target_h),0); ImageDraw.Draw(mask).rounded_rectangle((0,0,target_w,target_h),36,fill=255)
    im.paste(src, (box[0],box[1]),mask)
    d=ImageDraw.Draw(im); d.rounded_rectangle(box,36,outline=(255,255,255,30),width=3)

cards = [
 ('01-cover','拾响','让散落的声音，\n回到它该在的位置。','by Jacksun · 原生 macOS 音效管理器'),
 ('02-problem','每一次找音效，\n都不该打断创作。','不是“素材很多”，而是\n关键的一秒，找不到那个声音。','为剪辑现场而生'),
 ('03-library','5 万个声音，\n也能回到手边。','搜索、分类、波形试听、收藏。\n让硬盘里的音效库真正可用。','本地资料库 · 快速定位'),
 ('04-search','用创作者的话，\n找到创作者要的声音。','支持中文、文件名、时长、格式与本地语义搜索。\n“推进镜头”“悬疑”“2–5 秒”都可以试。','完全在本机完成'),
 ('05-preview','先听，再决定。','波形定位、A/B 片段循环、试听队列。\n不是打开文件夹后的盲猜。','给节奏一个确定的判断'),
 ('06-fcp','听到对的，\n就拖进 Final Cut Pro。','原文件直接拖入时间线。\n少一步切换，多一点沉浸。','为剪辑工作流而做'),
 ('07-private','素材只属于你。','不上传音频，不改动原文件。\n索引、波形、收藏与标签都在本机。','本地优先 · 隐私清楚'),
 ('08-maker','我不是为了做软件\n才做拾响。','我是因为做片子时，太熟悉那些\n被找素材打断的瞬间。','把反复发生的痛点，做成工具'),
 ('09-cta','拾响 · 本地创作者版','一个仍在持续打磨的开始。\n如果你也是剪辑师、导演或声音控，欢迎聊聊。','Jacksun · 2026'),
]

for idx,(name,title,body,kicker) in enumerate(cards):
    im=base(); d=ImageDraw.Draw(im)
    icon=Image.open(ICON).convert('RGBA').resize((96,96),Image.Resampling.LANCZOS)
    im.alpha_composite(icon,(94,88)); text(d,(214,124),'拾响',48); text(d,(214,183),'Shixiang · by Jacksun',24,MUTED)
    text(d,(96,340),title,88 if idx else 106,WHITE)
    text(d,(98,710),body,43 if idx else 47, '#D8D1E2')
    text(d,(100,1450),kicker,29,GOLD)
    wave(d,100,1335,960,42,(120,103,255,145))
    if idx in [0,2,3,4,5,6,8]:
        box=(100,850,1500,1260) if idx in [0,8] else (100,875,1500,1330)
        paste_shot(im,box,'center')
    elif idx==1:
        for x in [100,430,760,1090]:
            rounded(d,(x,1000,x+260,1200),(28,23,42,255),28)
            wave(d,x+35,1100,190,28,(230,189,112,160),18)
    elif idx==7:
        rounded(d,(100,930,1500,1280),(25,20,37,245),40,outline=(255,255,255,25),width=2)
        text(d,(150,1000),'“我想把那些反复找声音的时间，\n还给真正的创作。”',52,WHITE)
    im.convert('RGB').save(SOCIAL/f'{name}.jpg',quality=94)

# PDF uses selected cards as full-bleed pages and structured copy on alternating pages.
pdf = OUT/'拾响_产品介绍册_2026.pdf'
PW, PH = 1920, 1080
c = canvas.Canvas(str(pdf), pagesize=(PW,PH))
def draw_img(path):
    c.drawImage(ImageReader(str(path)),0,0,width=PW,height=PH)
    c.showPage()
def fill(hex): c.setFillColor(HexColor(hex))
def ct(s,x,y,size,color=WHITE):
    fill(color); c.setFont('Heiti',size); c.drawString(x,y,s)
def lines(arr,x,y,size=38,leading=58,color='#D8D1E2'):
    fill(color); c.setFont('Heiti',size)
    for z in arr: c.drawString(x,y,z); y-=leading
def header(label,num):
    fill('#0C0A12'); c.rect(0,0,PW,PH,fill=1,stroke=0)
    ct('拾响  /  Shixiang',94,970,30,GOLD); ct(f'{num:02d}',1760,970,26,MUTED); ct(label,94,850,78)

draw_img(SOCIAL/'01-cover.jpg')
header('为创作现场而生',2)
lines(['拾响不是一个“把文件装进去”的资料库。','它是一张被重新整理过的声音工作台：','从硬盘中找到、试听、判断，再进入剪辑时间线。'],96,700,44,72)
for i,(a,b) in enumerate([('更快找到','中文 / 原名 / 时长 / 格式 / 本地语义搜索'),('更顺手试听','波形定位、A/B 循环、试听队列'),('更少打断','原文件拖入 Final Cut Pro')]):
    x=96+i*580; c.setFillColor(HexColor('#181422')); c.roundRect(x,210,510,270,28,fill=1,stroke=0); ct(a,x+34,405,38,WHITE); lines([b],x+34,335,27,42,MUTED)
c.showPage()
draw_img(SOCIAL/'03-library.jpg')
draw_img(SOCIAL/'04-search.jpg')
draw_img(SOCIAL/'05-preview.jpg')
draw_img(SOCIAL/'06-fcp.jpg')
draw_img(SOCIAL/'07-private.jpg')
draw_img(SOCIAL/'08-maker.jpg')
header('首发时，怎么发布',10)
lines(['先发一条朋友圈，不把它写成“产品说明书”。','配九张图：封面 → 痛点 → 真实界面 → 搜索 → 试听 → FCP → 隐私 → 自述 → 邀请。','朋友圈正文只讲你为什么做；功能让图片自己说话。'],96,700,38,64)
ct('建议首发正文',96,420,34,GOLD)
lines(['做剪辑这些年，我越来越确定：找声音，是创作里最容易被忽略的消耗。','所以我给自己做了一个本地音效管理器，叫「拾响」。','它不上传素材，不改原文件；把硬盘里散落的声音整理成可搜索、可试听、','能直接拖进 Final Cut Pro 的工作台。','不是为了证明我会写软件。','是想把那些被找素材打断的时刻，尽量还给创作本身。'],96,350,32,48,WHITE)
c.showPage(); c.save()
print(pdf)
