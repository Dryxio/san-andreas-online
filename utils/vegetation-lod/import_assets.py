#!/usr/bin/env python3
from pathlib import Path
import struct,collections
import argparse
parser=argparse.ArgumentParser(description='Import reviewed LOD Vegetation assets and verified GTA model mappings')
parser.add_argument('--source',type=Path,required=True,help='Extracted LOD Vegetation folder')
parser.add_argument('--gta-data',type=Path,required=True,help='GTA data folder containing original IDE files')
parser.add_argument('--gta-img',type=Path,required=True,help='Original gta3.img used to match day/night prelight')
args=parser.parse_args()
root=args.source
def textinst(f):
 out=[];inside=False
 for l in f.read_text(errors='replace').splitlines():
  l=l.split('#',1)[0].strip()
  if l.lower()=='inst':inside=True;continue
  if l.lower()=='end':inside=False
  if inside and l and not l.startswith('#'):
   a=[v.strip() for v in l.split(',')];out.append((int(a[0]),tuple(map(float,a[3:6])),int(a[-1])))
 return out
maps={f.stem.lower():textinst(f) for f in (root/'map/data/maps').rglob('*') if f.suffix.lower()=='.ipl'}
links=collections.defaultdict(collections.Counter)
for f in (root/'map/gta3.img').glob('*.ipl'):
 b=f.read_bytes();n=struct.unpack_from('<I',b,4)[0];off=struct.unpack_from('<I',b,28)[0];base=maps[f.stem.lower().split('_stream')[0]]
 for i in range(n):
  a=struct.unpack_from('<7f3i',b,off+i*40);mid,area,lod=a[7:]
  if 0<=lod<len(base):
   lm,pos,_=base[lod]
   if lm>=12004 and lm<=12092:links[lm][mid]+=1
for base in maps.values():
 for mid,pos,lod in base:
  if 0<=lod<len(base):
   lm,lp,_=base[lod]
   if 12004<=lm<=12092:links[lm][mid]+=1
import json,shutil,hashlib
repo=Path(__file__).resolve().parents[2];dest=repo/'Shared/data/MTA San Andreas/MTA/data/vegetation-lod';dest.mkdir(parents=True,exist_ok=True)
base={};byid={}
for f in args.gta_data.rglob('*'):
 if f.suffix.lower()!='.ide':continue
 for line in f.read_text(errors='replace').splitlines():
  a=[v.strip() for v in line.split('#',1)[0].split(',')]
  if len(a)>=5 and a[0].isdigit():
   try: row=(int(a[0]),a[1],float(a[3]));base[a[1].lower()]=row;byid[row[0]]=row
   except ValueError:pass
rows=[];skipped=[]
for line in (root/'LODvegetation.ide').read_text().splitlines():
 a=[v.strip() for v in line.split(',')]
 if len(a)<5:continue
 modid=int(a[0]);name=a[1];asset=root/'trees'/f'{name}.dff'
 if not asset.exists():skipped.append({'model':name,'reason':'DFF absent from supplied archive'});continue
 candidates=list(links[modid])
 if len(candidates)>1:raise ValueError((name,candidates))
 source=byid.get(candidates[0]) if candidates else base.get(name[3:].lower(),base.get(name.lower()))
 if not source:skipped.append({'model':name,'reason':'No verified stock model or IPL link'});continue
 mid,sourceName,draw=source
 shutil.copyfile(asset,dest/asset.name)
 rows.append({'id':mid,'source':sourceName,'asset':asset.name,'transition':max(120,min(draw,250)),'range':float(a[3]),'sha256':hashlib.sha256(asset.read_bytes()).hexdigest(),'evidence':'IPL link' if candidates else 'exact model name'})
assert len({r['id'] for r in rows})==len(rows)
shutil.copyfile(root/'trees/LODvegetation.txd',dest/'LODvegetation.txd')
shutil.copyfile(root.parent/'Readme (or die).txt',dest/'Original-Readme.txt')
(dest/'manifest.json').write_text(json.dumps({'source':'LOD Vegetation v1.2 by Junior_Djjr / MixMods','models':sorted(rows,key=lambda r:r['id']),'excluded':skipped},indent=2)+'\n')
(repo/'Client/game_sa/CVegetationLODModelsSA.inc').write_text('// Verified stock model mappings. See MTA/data/vegetation-lod/manifest.json.\n'+''.join(f'    {{{r["id"]}, "{r["asset"]}", {r["transition"]:.1f}f, {r["range"]:.1f}f}}, // {r["source"]}\n' for r in sorted(rows,key=lambda r:r['id'])))
print('Included',len(rows),'excluded',skipped)

# The pack's generic lighting must not reappear when assets are reimported.
import subprocess,sys
subprocess.run([sys.executable,str(repo/'utils/vegetation-lod/match_prelight.py'),'--gta-img',str(args.gta_img)],check=True)
