"""Execute GTA's real damage-response routine with the repository's byte patch.

Usage: python test_forwarded_damage_stack.py /path/to/gta_sa_compact1.0.exe
Requires Unicorn (pip install unicorn); no game assets are redistributed.
Only the alive check, task lookup and player check are stubbed. The history
comparison, function frame, SEH restoration and return execute real x86 code.
This is an ABI regression test, not a multiplayer gameplay test.
"""
from pathlib import Path
import re
import struct
import sys
import unittest

from unicorn import Uc, UcError, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import (
    UC_X86_REG_EAX, UC_X86_REG_EBP, UC_X86_REG_EBX, UC_X86_REG_ECX,
    UC_X86_REG_EDI, UC_X86_REG_EIP, UC_X86_REG_ESI, UC_X86_REG_ESP,
)

EXE = Path(sys.argv.pop(1)).read_bytes()
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Client/multiplayer_sa/CMultiplayerSA.cpp'
PATCH_ADDRESS = 0x4C01F0
RETURN = 0x2000200
STACK = 0x177FC48
SEH = 0x177FF64


def unpack(fmt, data, offset):
    return struct.unpack_from('<' + fmt, data, offset)


def word(cpu, address, value):
    cpu.mem_write(address, struct.pack('<I', value))


def repository_patch():
    writes = dict((int(address, 16), int(value, 16)) for address, value in
                  re.findall(r'MemPut<BYTE>\((0x[0-9A-Fa-f]+), (0x[0-9A-Fa-f]+)\)', SOURCE.read_text()))
    return bytes(writes[PATCH_ADDRESS + i] for i in range(5))


def run_response(patch, history_type=9, same_damage=False, comparisons=None):
    cpu = Uc(UC_ARCH_X86, UC_MODE_32)
    cpu.mem_map(0, 0x1000)  # FS:[0], the x86 SEH head
    cpu.mem_map(0x400000, 0x900000)
    cpu.mem_map(0x1770000, 0x10000)
    cpu.mem_map(0x2000000, 0x10000)
    pe, = unpack('I', EXE, 0x3C)
    count, = unpack('H', EXE, pe + 6)
    optional_size, = unpack('H', EXE, pe + 20)
    base, = unpack('I', EXE, pe + 52)
    if base != 0x400000:
        raise ValueError('Expected the GTA SA 1.0 executable at image base 0x400000')
    for index in range(count):
        _, rva, size, raw = unpack('IIII', EXE, pe + 24 + optional_size + index * 40 + 8)
        if size and base + rva + size <= 0xD00000:
            cpu.mem_write(base + rva, EXE[raw:raw + size])
    # Fail closed on another executable/variant: these bytes establish the
    # pushed argument, callee cleanup and the SEH-aware epilogue under test.
    for address, expected in (
        (0x4C01ED, bytes.fromhex('50 8b ce e8 fb d9 fe ff')),
        (0x4ADC04, bytes.fromhex('b0 01 c2 04 00')),
        (0x4C0BB1, bytes.fromhex('5e 5d 5b 8b 4c 24 50 5f 64 89 0d 00 00 00 00 83 c4 58 c2 10 00')),
    ):
        if bytes(cpu.mem_read(address, len(expected))) != expected:
            raise ValueError(f'Unsupported GTA bytes at {address:#x}; use the unmodified compact 1.0 executable')
    if patch is not None:
        cpu.mem_write(PATCH_ADDRESS, patch)

    handler, ped, intelligence = 0x2001000, 0x2002000, 0x2003000
    event, history, vtable = 0x2004000, 0x2005000, 0x2006000
    word(cpu, handler, ped)
    word(cpu, ped + 0x47C, intelligence)
    word(cpu, handler + 0xC, history if history_type is not None else 0)
    word(cpu, history, vtable)
    word(cpu, vtable + 4, 0x2000100)
    cpu.mem_write(0x2000100, b'\xb8' + struct.pack('<I', history_type or 0) + b'\xc3')
    # m_bAddToEventGroup=false selects the social/forwarded-damage branch.
    # Null source stops after classification, before unrelated AI allocation.
    cpu.mem_write(event + 0xC, b'\0')
    word(cpu, event + 0x1C, 0)
    word(cpu, history + 0x1C, 0 if same_damage else 1)
    word(cpu, 0, SEH)
    for index, value in enumerate((RETURN, event, 0, 0, 0)):
        word(cpu, STACK + 4 * index, value)
    saved = {UC_X86_REG_EBX: 0x11111111, UC_X86_REG_EBP: 0x22222222,
             UC_X86_REG_ESI: 0x33333333, UC_X86_REG_EDI: 0x44444444}
    for register, value in saved.items():
        cpu.reg_write(register, value)
    cpu.reg_write(UC_X86_REG_ECX, handler)
    cpu.reg_write(UC_X86_REG_ESP, STACK)

    def stub(cpu, address, size, data):
        if address == 0x4C01F5 and comparisons is not None:
            comparisons.append(cpu.reg_read(UC_X86_REG_EAX) & 0xFF)
        calls = {0x5E0170: (1, 0), 0x681740: (0, 4), 0x5DF8F0: (0, 0)}
        if address in calls:
            result, cleanup = calls[address]
            sp = cpu.reg_read(UC_X86_REG_ESP)
            target, = unpack('I', cpu.mem_read(sp, 4), 0)
            cpu.reg_write(UC_X86_REG_EAX, result)
            cpu.reg_write(UC_X86_REG_ESP, sp + 4 + cleanup)
            cpu.reg_write(UC_X86_REG_EIP, target)

    cpu.hook_add(UC_HOOK_CODE, stub)
    try:
        cpu.emu_start(0x4C0170, RETURN, count=1000)
    except UcError:
        if cpu.reg_read(UC_X86_REG_EIP) != 0xFFFFFFFF:
            raise
    return cpu, saved


class ForwardedDamageStack(unittest.TestCase):
    def assert_balanced(self, cpu, saved):
        self.assertEqual(cpu.reg_read(UC_X86_REG_EIP), RETURN)
        self.assertEqual(cpu.reg_read(UC_X86_REG_ESP), STACK + 20)
        self.assertEqual(unpack('I', cpu.mem_read(0, 4), 0)[0], SEH)
        for register, value in saved.items():
            self.assertEqual(cpu.reg_read(register), value)

    def test_original_callee_balances_argument(self):
        self.assert_balanced(*run_response(None))

    def test_old_patch_reproduces_invalid_return_and_seh(self):
        cpu, _ = run_response(bytes.fromhex('b0 00 90 90 90'))
        self.assertEqual(cpu.reg_read(UC_X86_REG_EIP), 0xFFFFFFFF)
        self.assertEqual(cpu.reg_read(UC_X86_REG_ESP), STACK + 16)
        self.assertNotEqual(unpack('I', cpu.mem_read(0, 4), 0)[0], SEH)

    def test_repository_patch_preserves_frame_for_each_history_branch(self):
        for event_type in (None, 31, 9):
            with self.subTest(history_type=event_type):
                self.assert_balanced(*run_response(repository_patch(), event_type))

    def test_same_damage_still_has_the_existing_forced_false_policy(self):
        original, patched = [], []
        self.assert_balanced(*run_response(None, same_damage=True, comparisons=original))
        self.assert_balanced(*run_response(repository_patch(), same_damage=True, comparisons=patched))
        self.assertEqual(original, [1])
        self.assertEqual(patched, [0])


if __name__ == '__main__':
    unittest.main()
