from pathlib import Path
import math, html, json
OUT=Path(__file__).parent
PAPER='#FCFAF3'; INK='#252B29'; MUTED='#69716C'; LINE='#DDDFD7'
PINE='#2A5F45'; RED='#9E3324'; BLUE='#27356B'
def text(x,y,s,size=14,color=INK,weight=400,anchor='start',spacing=0):
 return f'<text x="{x}" y="{y}" font-family="Arial, Helvetica, sans-serif" font-size="{size}" font-weight="{weight}" fill="{color}" stroke="none" text-anchor="{anchor}" letter-spacing="{spacing}">{html.escape(s)}</text>'
def path(d,sw=3,fill='none'):
 return f'<path d="{d}" stroke-width="{sw}" fill="{fill}"/>'
def line(x1,y1,x2,y2,sw=2):return f'<path d="M{x1} {y1}H{x2}" stroke-width="{sw}"/>' if y1==y2 else path(f'M{x1} {y1}L{x2} {y2}',sw)
def arc(s,top,color,size=14,r=91):
 step=(size*.68+1.0)/r
 total=step*(len(s)-1)
 out=''
 for i,c in enumerate(s):
  a=(-math.pi/2-total/2+i*step) if top else (math.pi/2+total/2-i*step)
  x=120+r*math.cos(a);y=120+r*math.sin(a)
  rotation=math.degrees(a)+(90 if top else -90)
  out+=f'<g transform="translate({x:.2f} {y:.2f}) rotate({rotation:.2f})">'+text(0,0,c,size,color,700,'middle')+'</g>'
 return out
def pine(x,y,s=1):
 return f'<g transform="translate({x} {y}) scale({s})">'+path('M0 0L-12 21H-6L-18 37H-9L-23 55H23L9 37H18L6 21H12Z',2,'currentColor')+path('M0 52V65',4)+'</g>'
art={
'yosemite':path('M53 150L75 119L89 130L113 92Q138 62 166 89L178 128L191 151Z',3)+path('M113 92L115 125L106 145M124 83L130 108L128 148M137 80L145 107L146 149M150 82L160 110L164 148',1.7)+path('M62 152H187',3)+pine(68,108,.54)+pine(184,117,.42)+f'<circle cx="77" cy="91" r="9" stroke-width="2"/>',
'kyoto':path('M57 147Q79 140 120 103Q161 140 183 147H57Z',3)+path('M79 151V160H161V151M87 129V144M153 129V144M108 142V159M131 142V159',3)+path('M72 119Q94 112 120 84Q147 112 168 119H72Z',3)+path('M94 121V132M146 121V132M103 112V121M137 112V121',3)+path('M89 91Q109 82 120 62Q132 82 151 91H89Z',3)+path('M107 93V103M133 93V103M120 52V66',3)+path('M48 164H191',3)+pine(184,103,.58),
 'tokyo':path('M73 151V116Q73 99 90 99H151Q168 99 168 116V151Z',3)+path('M84 109H157V131H84ZM118 109V131M81 143H160M85 152L77 162M154 152L162 162',2.8)+f'<circle cx="87" cy="139" r="3" fill="currentColor"/><circle cx="154" cy="139" r="3" fill="currentColor"/>'+path('M113 89L123 58L133 89M117 80H129M121 59V48M125 59V48M57 132V87H75V96M164 99V73H180V132M164 85H180',2.5)+path('M57 162H182',2),
 'tahoe':path('M51 119L89 79L109 98L139 68L186 119M76 94L90 99L99 91M124 85L139 92L151 83',3)+path('M53 129Q68 122 83 129T113 129T143 129T173 129T193 129M62 141Q78 134 94 141T126 141T158 141T187 141M76 153Q90 146 107 153T141 153T168 153',3)+pine(62,89,.44),
 'san-francisco':path('M51 145H190M52 135H189M80 146V78H93V146M148 146V78H161V146M80 93H93M148 93H161M80 113H93M148 113H161',3.5)+path('M47 126Q73 119 80 81M93 81Q120 145 148 81M161 81Q168 119 194 126',3)+path('M57 122V135M68 111V135M102 100V135M112 116V135M123 123V135M134 115V135M175 112V135M186 122V135',1.8)+path('M64 157Q80 151 96 157T128 157T160 157T184 157',2),
 'nara':path('M106 156L102 128Q91 109 97 94L111 83L121 84L129 92L143 99L141 109L128 111L123 128L134 156M107 117L115 126M108 138L111 156M125 137L120 156',3.5)+path('M101 95Q82 80 82 74Q98 73 109 86M121 87Q135 70 145 77Q145 86 128 97',3)+path('M108 85L107 63L99 53M107 69L118 53M99 53L99 45M98 54L89 51M118 53L120 44M118 54L127 51',3)+f'<circle cx="126" cy="99" r="2.4" fill="currentColor"/>'+path('M68 158H177',2)+pine(71,106,.58)
}
data=[
 dict(id='yosemite',name='Yosemite',country='California · USA',date='JUN 2026',caption='June 2026',ink=PINE,shape='round',kind='PARK SEAL'),
 dict(id='kyoto',name='Kyoto',country='Japan',date='MAR 2026',caption='March 2026',ink=RED,shape='square',kind='STATION SEAL'),
 dict(id='tokyo',name='Tokyo',country='Japan',date='MAR 2026',caption='March 2026',ink=BLUE,shape='round',kind='STATION SEAL'),
 dict(id='tahoe',name='Lake Tahoe',country='California · USA',date='JUN 2026',caption='June 2026',ink=BLUE,shape='round',kind='PARK SEAL'),
 dict(id='san-francisco',name='San Francisco',country='California · USA',date='JUN 2026',caption='June 2026',ink=RED,shape='round',kind='CITY SEAL'),
 dict(id='nara',name='Nara',country='Japan',date='MAR 2026',caption='March 2026',ink=PINE,shape='square',kind='STATION SEAL')]
from additional_locations import build_expansion
more_art, more_places = build_expansion(path, pine)
art.update(more_art)
data.extend(more_places)

def stamp(d,compact=False):
 c=d['ink']; out=f'<g id="stamp-{d["id"]}" color="{c}" stroke="{c}" fill="none" stroke-linecap="round" stroke-linejoin="round">'
 if d['shape']=='round':
  out+='<circle cx="120" cy="120" r="109" stroke-width="3.8"/><circle cx="120" cy="120" r="102" stroke-width="1.1"/>'
  out+=arc(d['name'].upper(),True,c,14 if len(d['name'])<13 else 12.5,r=84)
  out+=arc(d['country'].upper(),False,c,9.5)
  out+=f'<circle cx="28" cy="122" r="2.6" fill="{c}"/><circle cx="212" cy="122" r="2.6" fill="{c}"/>'
 else:
  out+=path('M38 17H202L223 38V202L202 223H38L17 202V38Z',3.8)+path('M40 24H200L216 40V200L200 216H40L24 200V40Z',1.1)
  out+=text(120,49,d['name'].upper(),18,c,700,'middle',2.5)
  out+=text(120,205,d['country'].upper(),10,c,700,'middle',2.8)
 out+=(('<g transform="translate(18 21.5) scale(.85)">'+art[d['id']]+'</g>') if d['id']=='nara' else art[d['id']])
 out+=path('M76 169H164',1.3)+text(120,185,d['date'],11,c,700,'middle',1.3)
 out+='</g>'
 return out.replace('currentColor',c)
def svg(body,w,h):return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>'
def use(d,x,y,size=240,tilt=0):
 # Repeated placements must not duplicate SVG element IDs on presentation boards.
 artwork = stamp(d).replace(f' id="stamp-{d["id"]}"', '')
 return f'<g transform="translate({x} {y}) scale({size/240}) rotate({tilt} 120 120)">{artwork}</g>'
for d in data:(OUT/(d['id']+'.svg')).write_text(svg(stamp(d),240,240))
# Design presentation board — vector shapes, editable text, no raster assets.
b=f'<rect width="1600" height="1340" fill="{PAPER}"/>'
b+=text(64,65,'TRIPSPLIT  /  LOCATION STAMPS',13,PINE,700,spacing=2)
b+=text(1536,65,'DESIGN STUDY 01',12,MUTED,400,'end',2)
b+=text(60,140,'Places worth keeping.',58,INK,700,spacing=-2)
b+=text(64,180,'Passport ink. Local landmarks. A quieter way to remember where you’ve been.',18,MUTED)
b+=f'<path d="M64 215H1536" stroke="#DDDFD7"/>'
b+=text(64,250,'THE STAMP FAMILY',11,MUTED,700,spacing=1.8)
b+=text(1065,250,'IN CONTEXT  /  PROPOSED COLLECTION VIEW',11,MUTED,700,spacing=1.6)
for i,d in enumerate(data[:6]):
 x=70+(i%3)*314; y=282+(i//3)*328
 b+=use(d,x,y,246,[-2,1,2,1,-2,-1][i])
 b+=text(x+123,y+275,d['kind'],10,MUTED,700,'middle',1.8)
# Phone, simplified system chrome. Example data only.
px,py=1070,277
phone='<rect width="410" height="880" rx="46" fill="#252B29"/>'
phone+='<rect x="7" y="7" width="396" height="866" rx="40" fill="#FFFFFF"/>'
phone+='<rect x="145" y="19" width="120" height="26" rx="13" fill="#252B29"/>'
phone+=text(34,40,'9:41',13,INK,700)+text(367,40,'•••',15,INK,700,'end')
phone+=path('M36 77L29 84L36 91',2).replace('<path','<path stroke="#256A99"')+text(43,90,'Profile',16,'#256A99')
phone+='<circle cx="363" cy="85" r="20" fill="#F2F5F6"/>'+f'<path d="M356 85H370M363 78V92" stroke="#256A99" stroke-width="2" stroke-linecap="round"/>'
phone+=text(29,136,'Where I’ve been',29,INK,700,spacing=-.6)+text(30,165,'6 places  ·  2 countries',14,MUTED)
phone+='<path d="M29 190H381" stroke="#E9EBE7"/>'
for i,d in enumerate(data[:6]):
 x=37+(i%2)*186;y=211+(i//2)*200
 phone+=use(d,x,y,150,[-1,1,1,-1,-2,1][i])
 phone+=text(x+75,y+169,d['name'],14,INK,700,'middle')+text(x+75,y+188,d['caption'],12,MUTED,400,'middle')
phone+='<rect x="145" y="852" width="120" height="5" rx="2.5" fill="#252B29"/>'
b+=f'<g transform="translate({px} {py})">{phone}</g>'
b+=text(1275,1189,'Clear labels stay outside the artwork.',13,MUTED,400,'middle')
# Existing profile rail at actual display size, a practical compact use case.
b+=f'<rect x="64" y="972" width="916" height="255" rx="20" fill="#FFFFFF" stroke="#E1E3DC"/>'
b+=text(88,1010,'Where I’ve been',21,INK,700)+text(940,1010,'+',26,'#256A99',400,'end')
for i,d in enumerate(data[:3]):
 x=88+i*150
 b+=use(d,x,1032,128)+text(x+64,1180,d['name'],13,INK,700,'middle')+text(x+64,1198,d['caption'],11,MUTED,400,'middle')
b+=text(580,1065,'128 pt',27,INK,700)+text(580,1094,'Actual-size profile rail',14,MUTED)
b+=text(580,1133,'Same footprint. Stronger place identity.',13,MUTED)+text(580,1156,'Add and edit remain within reach.',13,MUTED)
b+=f'<path d="M64 1265H1536" stroke="#DDDFD7"/>'
for x,c,label in [(64,PINE,'PINE'),(212,BLUE,'INDIGO'),(375,RED,'OXBLOOD')]:
 b+=f'<circle cx="{x+6}" cy="1301" r="6" fill="{c}"/>'+text(x+21,1305,label,10,MUTED,700,spacing=1.5)
b+=text(1536,1305,'One ink per stamp  /  Original artwork  /  Illustrative dates',12,MUTED,400,'end')
(OUT/'location-stamps-mockup.svg').write_text(svg(b,1600,1340))
# Expanded catalog. Each location keeps its own vector artwork and a readable caption.
countries=sorted(set('USA' if d['country'].endswith('USA') else d['country'] for d in data))
catalog=f'<rect width="1600" height="1175" fill="{PAPER}"/>'
catalog+=text(64,61,'TRIPSPLIT  /  LOCATION STAMPS',13,PINE,700,spacing=2)
catalog+=text(1536,61,'EXPANDED COLLECTION 02',12,MUTED,400,'end',2)
catalog+=text(60,134,'More places. Same passport.',53,INK,700,spacing=-1.8)
catalog+=text(64,176,f'{len(data)} original stamps · {len(countries)} countries · 12 additions drawn from the app’s locations',17,MUTED)
catalog+='<path d="M64 210H1536" stroke="#DDDFD7"/>'
for i,d in enumerate(data):
    x=63+(i%6)*247;y=245+(i//6)*284
    catalog+=use(d,x,y,220,[-1,1,1,-1,-2,1][i%6])
    catalog+=text(x+110,y+244,d['name'],15,INK,700,'middle')
    label=d.get('landmark',d['kind'])
    catalog+=text(x+110,y+265,label,9,MUTED,700,'middle',.9)
catalog+='<path d="M64 1120H1536" stroke="#DDDFD7"/>'
catalog+=text(64,1151,'Pine / Indigo / Oxblood · One ink per place · Illustrative visit dates',12,MUTED)
catalog+=text(1536,1151,'Original six in row 1 · New additions in rows 2–3',12,MUTED,400,'end')
(OUT/'location-stamps-expanded.svg').write_text(svg(catalog,1600,1175))

# Lightweight browsable prototype. SVG artwork remains the source for Figma import.
assets={d['id']:svg(stamp(d),240,240) for d in data}
page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TripSplit · Location stamps</title><style>
*{box-sizing:border-box}body{margin:0;background:#fcfaf3;color:#252b29;font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}main{max-width:1200px;margin:auto;padding:52px 28px}header small{color:#2a5f45;letter-spacing:.18em;font-weight:650}h1{font-size:clamp(36px,6vw,62px);letter-spacing:-.045em;margin:20px 0 12px}header p{color:#69716c;font-size:18px;line-height:1.6}nav{display:flex;gap:8px;margin:30px 0 20px;flex-wrap:wrap}button,a{font:inherit}nav button,.close{min-height:44px;padding:10px 20px;border:1px solid #d9ded6;border-radius:24px;background:transparent;cursor:pointer;color:inherit}nav button[aria-pressed=true]{background:#2a5f45;color:white;border-color:#2a5f45}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}.stamp{border:0;border-radius:18px;background:#fff;padding:28px;cursor:pointer;color:inherit}.stamp:hover{background:#f0f2e9}.stamp:focus-visible,button:focus-visible,a:focus-visible{outline:3px solid #256a99;outline-offset:4px}.stamp svg{width:100%;max-width:235px;display:block;margin:auto}.stamp strong{display:block;font-size:17px;margin:17px 0 7px}.stamp span{color:#69716c;font-size:14px}.mockup{width:100%;margin-top:40px;border:1px solid #e1e3dc;border-radius:16px}footer{display:flex;gap:24px;flex-wrap:wrap;border-top:1px solid #ddd;margin-top:30px;padding-top:25px;color:#69716c;font-size:14px}a{color:#256a99}dialog{border:0;border-radius:24px;padding:32px;width:min(440px,92vw);text-align:center;background:#fcfaf3;color:#252b29}dialog::backdrop{background:#17271b80}dialog svg{max-width:290px;width:100%;margin-top:12px}dialog h2{margin-bottom:8px}dialog p{color:#69716c;line-height:1.6}.close{float:right;font-size:15px}dialog a{display:inline-block;margin:12px}body.dark{background:#171d1a;color:#f3f2e9}body.dark header p,body.dark footer{color:#c1c8c2}body.dark .stamp{background:#242d27;color:#f3f2e9}body.dark .stamp span{color:#c1c8c2}body.dark nav button{border-color:#5d7162}body.dark .stamp svg{background:#fcfaf3;border-radius:50%}@media(max-width:700px){main{padding:32px 18px}.grid{grid-template-columns:repeat(2,1fr);gap:12px}.stamp{padding:15px}.stamp strong{font-size:15px}footer{line-height:1.7}}
</style><main><header><small>TRIPSPLIT / EXPANDED COLLECTION 02</small><h1>Places worth keeping.</h1><p>Passport ink. Local landmarks. A quieter way to remember where you’ve been.</p></header><nav aria-label="Stamp collection"><button data-filter="all" aria-pressed="true">All places</button><button data-filter="USA" aria-pressed="false">United States</button><button data-filter="Japan" aria-pressed="false">Japan</button><button data-filter="France" aria-pressed="false">France</button><button data-filter="UK" aria-pressed="false">UK</button><button data-filter="Italy" aria-pressed="false">Italy</button><button data-filter="South Korea" aria-pressed="false">South Korea</button><button data-filter="Singapore" aria-pressed="false">Singapore</button><button data-filter="Australia" aria-pressed="false">Australia</button></nav><section class="grid" aria-label="Select a stamp to see its detail"></section><img class="mockup" src="location-stamps-mockup.svg" alt="The original six-stamp collection screen and profile rail mockup."><footer><a href="location-stamps-expanded.svg" download>Download 18-stamp SVG board</a><a href="location-stamps-mockup.svg" download>Download editable SVG board</a><a href="location-stamps-figma-kit.zip" download>Download Figma import kit</a><span>Mockup only · Dates are illustrative</span></footer></main><dialog><button class="close">Close</button><div id="detail"></div></dialog><script>'''
page+='const places='+json.dumps(data)+';const art='+json.dumps(assets)+';'
page+='''const grid=document.querySelector('.grid'),dialog=document.querySelector('dialog');function render(filter='all'){grid.innerHTML='';places.filter(p=>filter==='all'||p.country.includes(filter)).forEach(p=>{const b=document.createElement('button');b.className='stamp';b.setAttribute('aria-label',p.name+', '+p.caption+'. View stamp');b.innerHTML=art[p.id]+'<strong>'+p.name+'</strong><span>'+p.caption+'</span>';b.onclick=()=>{document.querySelector('#detail').innerHTML=art[p.id]+'<h2>'+p.name+'</h2><p>'+p.country+' · '+p.caption+'</p><a href="'+p.id+'.svg" download>Download editable stamp</a>';dialog.showModal()};grid.append(b)})}document.querySelectorAll('[data-filter]').forEach(b=>b.onclick=()=>{document.querySelectorAll('[data-filter]').forEach(x=>x.setAttribute('aria-pressed',x===b));render(b.dataset.filter)});document.querySelector('.close').onclick=()=>dialog.close();dialog.onclick=e=>{if(e.target===dialog)dialog.close()};render();</script></html>'''
(OUT/'index.html').write_text(page)
