#!/usr/bin/env python3
"""Exercise the production request/pulse bodies with a fake asset loader.

This checks scheduling and retry behavior, not RenderWare I/O or rendering.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
source = (ROOT / "Client/game_sa/CVegetationLODSA.h").read_text()
start = source.index("    inline bool Request(")
end = source.rfind("\n}")
prefix = r"""#include <array>
#include <cassert>
#include <cstddef>
#include <iostream>
struct CRenderWareSA{};
struct Asset { void* atomic{}; bool attempted{},requested{}; };
std::array<Asset,89> assets;
bool enabled=true,fail=false;
unsigned loads=0;
void Load(std::size_t index,CRenderWareSA*) { ++loads;assets[index].attempted=true;assets[index].atomic=fail?nullptr:&loads; }
"""
suffix = r"""
int main(){
 assert(!Request(4));assert(!Request(4));assert(loads==0);
 Request(7);Pulse(nullptr);assert(loads==1);assert(assets[4].atomic);assert(assets[7].requested);
 assert(Request(4));Pulse(nullptr);assert(loads==2);Pulse(nullptr);assert(loads==2);
 fail=true;Request(9);Pulse(nullptr);assert(loads==3);assert(!Request(9));Pulse(nullptr);assert(loads==3);
 Request(12);enabled=false;Pulse(nullptr);assert(loads==3);
 assets={};enabled=true;Pulse(nullptr);assert(loads==3); // disable/reset clears requests with assets
 fail=false;assert(!Request(9));Pulse(nullptr);assert(loads==4);assert(Request(9));
 for(std::size_t i=0;i<assets.size();++i)Request(i);
 for(unsigned i=0;i<88;++i){unsigned before=loads;Pulse(nullptr);assert(loads==before+1);}
 Pulse(nullptr);assert(loads==92);
 std::cout<<"actual Request/Pulse: bounded loading, no render-side load, failure latch and reset passed\n";
}
"""

with tempfile.TemporaryDirectory(prefix="neon-vegetation-queue-") as directory:
    check = Path(directory) / "check.cpp"
    check.write_text(prefix + source[start:end] + suffix)
    binary = Path(directory) / "check"
    subprocess.run(["clang++", "-std=c++17", "-fsanitize=address,undefined",
                    str(check), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
