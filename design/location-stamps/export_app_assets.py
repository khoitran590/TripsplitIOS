from pathlib import Path
import sys, runpy, json, os

# Run from any directory; artwork is generated from the approved mockup sources.
os.chdir(Path(__file__).resolve().parents[2])
sys.path.insert(0,str(Path('design/location-stamps').resolve()))
s=runpy.run_path('design/location-stamps/build_mockup.py');art=s['art'];path=s['path'];pine=s['pine']
art=dict(art)
art['nara']='<g transform="translate(18 21.5) scale(.85)">'+art['nara']+'</g>'
art.update({
'generic-city':path('M65 158V111H91V158M96 158V83H129V158M135 158V102H165V158M58 160H183M72 121H82M72 135H82M104 95H120M104 108H120M104 121H120M104 134H120M144 115H157M144 128H157M144 141H157',3),
'generic-mountain':path('M50 157L91 91L112 119L144 74L191 157ZM80 108L93 115L101 106M131 94L144 102L155 91',3),
'generic-lake':path('M51 119L89 79L109 98L139 68L186 119M76 94L90 99L99 91M124 85L139 92L151 83',3)+path('M53 129Q68 122 83 129T113 129T143 129T173 129T193 129M62 141Q78 134 94 141T126 141T158 141T187 141M76 153Q90 146 107 153T141 153T168 153',3),
'generic-coast':path('M51 125Q73 105 101 121Q132 144 159 109Q171 98 186 116M55 146Q70 137 85 146T115 146T145 146T175 146M73 159Q89 151 105 159T137 159T168 159',3)+'<circle cx="121" cy="82" r="16" stroke-width="3"/>',
'generic-island':path('M61 146Q120 119 179 146M51 160Q68 152 85 160T119 160T153 160T187 160M111 136Q126 105 120 83M120 83Q96 65 79 85Q100 77 120 83M120 83Q142 60 160 80Q140 76 120 83M120 83Q104 86 100 105M120 83Q135 88 142 102',3),
'generic-desert':path('M48 149Q88 119 130 147Q165 125 194 144M65 161H178M114 140V91Q114 82 122 82Q130 82 130 91V140M113 118H99Q91 118 91 109V99M131 109H142Q150 109 150 99V93',3)+'<circle cx="74" cy="82" r="12" stroke-width="3"/>',
'generic-forest':pine(121,73,1.15)+pine(70,107,.73)+pine(176,109,.7)+path('M49 160H192',3),
'generic-snow':path('M55 157L95 97L118 125L146 82L187 157M84 114L95 121L105 112M137 96L147 109L156 97M58 160H187M73 78V58M63 68H83M66 61L80 75M66 75L80 61',3),
'generic-historic':path('M58 100L120 76L182 100ZM67 107H173M75 109V151M93 109V151M113 109V151M132 109V151M151 109V151M167 109V151M62 154H178V161H62Z',3)
})
root=Path('Tripsplit/Assets.xcassets')
for name,drawing in art.items():
 folder=root/('stamp-'+name+'.imageset');folder.mkdir(exist_ok=True)
 body='<g stroke="#000000" fill="none" stroke-linecap="round" stroke-linejoin="round">'+drawing.replace('currentColor','#000000')+'</g>'
 (folder/('stamp-'+name+'.svg')).write_text(s['svg'](body,240,240))
 (folder/'Contents.json').write_text(json.dumps({'images':[{'filename':'stamp-'+name+'.svg','idiom':'universal'}],'info':{'author':'xcode','version':1},'properties':{'preserves-vector-representation':True,'template-rendering-intent':'template'}},indent=2)+'\n')
print('Installed',len(art),'vector illustrations (18 destinations + 9 generic themes).')
