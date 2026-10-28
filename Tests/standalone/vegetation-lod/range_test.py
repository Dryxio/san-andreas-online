#!/usr/bin/env python3
"""Check the production range function against every authored vegetation entry."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[3]
s = (root / 'Client/game_sa/CVegetationLODSA.h').read_text()
a = s.index('    inline float Range(')
b = s.index('    inline void Clear(', a)
body = s[a:b]
models = (root / 'Client/game_sa/CVegetationLODModelsSA.inc').read_text()
source = '#include <algorithm>\n#include <cassert>\n#include <iostream>\nstruct Definition { unsigned short model; const char* file; float transition,range; };\nfloat distanceLimit;\n' + body + '\nDefinition definitions[]={\n' + models + '};\n' + r"""
int main() {
 for(const auto& d: definitions) {
  distanceLimit=0; assert(Range(d)==d.range);
  float previous=0;
  for(int limit=1;limit<=2000;++limit) {
   distanceLimit=float(limit); const auto r=Range(d);
   assert(r<=d.range && r>=400 && r>d.transition);
   assert(r>=previous); previous=r;
   if(limit<400) assert(r==400);
   if(limit>=d.range) assert(r==d.range);
  }
 }
 std::cout<<"89 authored models: default, cap, transition margin and monotonicity passed\n";
}
"""
with tempfile.TemporaryDirectory(prefix='neon-veg-range-') as tmp:
 f=Path(tmp)/'check.cpp';f.write_text(source);binary=Path(tmp)/'check'
 subprocess.run(['clang++','-std=c++17','-fsanitize=address,undefined',str(f),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
