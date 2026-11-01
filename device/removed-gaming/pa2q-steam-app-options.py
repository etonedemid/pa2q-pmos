#!/usr/bin/env python3
# Per-game Steam settings in userdata/<id>/config/localconfig.vdf (text VDF).
# Steam rewrites this file on exit: run it only while Steam is stopped.
#   pa2q-steam-app-options.py LOCALCONFIG
# Isaac (250900): Steam Input off and the GameSir handed to the game as one
# XInput pad. With Steam Input on, the game saw Steam's virtual pad and the raw
# GameSir (Proton's hidraw path) as two controllers.
import re
import sys

GAMESIR = ("03000000373500001611000011010000,GameSir-X5-Lite,a:b0,b:b1,x:b3,y:b4,"
           "back:b10,guide:b12,start:b11,leftstick:b13,rightstick:b14,leftshoulder:b6,"
           "rightshoulder:b7,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,leftx:a0,"
           "lefty:a1,rightx:a2,righty:a3,lefttrigger:a5,righttrigger:a4,platform:Linux,")
APPS = {
    "250900": {
        "UseSteamControllerConfig": "0",      # Steam Input: off for this game
        # PROTON_PREFER_SDL: controllers through SDL only (no hidraw duplicate);
        # SDL then maps the GameSir to XInput with this mapping.
        "LaunchOptions": "PROTON_PREFER_SDL=1 SDL_GAMECONTROLLERCONFIG=%s %%command%%" % GAMESIR,
    },
}


def block_span(s, start):
    """Index just past the '}' closing the block whose '{' follows start."""
    i, depth = s.index("{", start), 0
    while True:
        c = s[i]
        if c == '"':
            i = s.index('"', i + 1)
            while s[i - 1] == "\\":
                i = s.index('"', i + 1)
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1


def set_keys(s, appid, keys):
    m = re.search(r'"apps"\s*\{', s)
    assert m, "no apps block"
    end_apps = block_span(s, m.start())
    a = re.compile(r'"%s"\s*\{' % appid).search(s, m.end(), end_apps)
    assert a, "app %s not in localconfig (launch it once first)" % appid
    end = block_span(s, a.start())
    block = s[a.start():end]
    indent = re.search(r"\n(\t*)\"", block).group(1) if "\n\t" in block else "\t\t\t\t\t\t"
    for k, v in keys.items():
        v = v.replace("\\", "\\\\").replace('"', '\\"')
        km = re.search(r'\n\t*"%s"\t+"(?:[^"\\]|\\.)*"' % k, block)
        line = '\n%s"%s"\t\t"%s"' % (indent, k, v)
        if km:
            block = block[:km.start()] + line + block[km.end():]
        else:
            nl = block.rindex("\n", 0, block.rindex("}"))   # line holding the closing brace
            block = block[:nl] + line + block[nl:]
    return s[:a.start()] + block + s[end:]


if __name__ == "__main__":
    path = sys.argv[1]
    s = open(path).read()
    for appid, keys in APPS.items():
        s = set_keys(s, appid, keys)
    open(path, "w").write(s)
    print("updated", ", ".join(APPS))
