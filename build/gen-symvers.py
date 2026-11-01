# Build a Module.symvers from the exports (+CRCs) of the stock vendor .ko files,
# skipping symbols the kernel objtree already provides. First module wins on dups.
import sys, glob, os, struct
from elftools.elf.elffile import ELFFile
base = set()
for l in open(os.path.expanduser('~/Desktop/Projects/phone-pmos/k698/out-698ns/Module.symvers')):
    p = l.rstrip('\n').split('\t')
    if len(p) > 1: base.add(p[1])
vdir = os.path.expanduser('~/Desktop/Projects/phone-pmos/pa2q-backup/vendor-modules-20260929/vendor')
seen = {}
for f in sorted(glob.glob(vdir + '/*.ko')):
    try:
        e = ELFFile(open(f, 'rb'))
        st = e.get_section_by_name('.symtab')
        if not st: continue
        secs = {s.name: s for s in e.iter_sections()}
        for sym in st.iter_symbols():
            n = sym.name
            if not n.startswith('__crc_'): continue
            s = e.get_section(sym['st_shndx']) if isinstance(sym['st_shndx'], int) else None
            if s is None: continue
            gpl = 'gpl' in s.name
            crc = struct.unpack('<I', s.data()[sym['st_value']:sym['st_value']+4])[0]
            name = n[6:]
            if name in base or name in seen: continue
            seen[name] = (crc, 'vendor/' + os.path.basename(f)[:-3], 'EXPORT_SYMBOL_GPL' if gpl else 'EXPORT_SYMBOL')
    except Exception as ex:
        print('skip', f, ex, file=sys.stderr)
out = sys.argv[1]
with open(out, 'w') as o:
    for n, (c, m, k) in sorted(seen.items()):
        o.write('0x%08x\t%s\t%s\t%s\t\n' % (c, n, m, k))
print(len(seen), 'symbols ->', out)
