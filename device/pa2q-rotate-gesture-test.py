#!/usr/bin/env python3
# Self-check for pa2q-rotate-gesture tap timing: feeds synthetic multitouch
# events through a pipe and records the actions. Run: python3 pa2q-rotate-gesture-test.py
import importlib.machinery, importlib.util, os, threading, time
loader = importlib.machinery.SourceFileLoader("g", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pa2q-rotate-gesture"))
spec = importlib.util.spec_from_loader("g", loader); g = importlib.util.module_from_spec(spec); loader.exec_module(g)
r, w = os.pipe(); got = []
g.touchscreen = lambda: "/dev/fd/%d" % r
g.flip = lambda: got.append("flip")
threading.Thread(target=g.main, daemon=True).start()
E = lambda t, c, v: os.write(w, g.EVENT.pack(0, 0, t, c, v))
def tap(n):
    for s in range(n): E(3, 0x2F, s); E(3, 0x39, 100 + s)
    E(0, 0, 0); time.sleep(0.1)
    for s in range(n): E(3, 0x2F, s); E(3, 0x39, -1)
    E(0, 0, 0)
def case(name, taps, gap, want):
    got.clear()
    for n in taps: tap(n); time.sleep(gap)
    time.sleep(0.9); assert got == want, (name, got); print("ok", name, got)
case("4 double", [4, 4], 0.2, ["flip"])
case("4 single", [4], 0, [])
case("3 double", [3, 3], 0.2, [])
case("4 slow pair", [4, 4], 0.8, [])
