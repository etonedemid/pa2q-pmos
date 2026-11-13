# Decky backend for the Phone Controls side menu. pa2q-clockd (root, host) reads the
# config and the reboot request: this plugin runs as the user in the Steam container.
import glob
import os
import re

CONF = "/home/etonedemid/.config/pa2q-clocks.conf"
REBOOT_REQUEST = "/home/etonedemid/.cache/pa2q-reboot-android"
BACKLIGHT = "/sys/class/backlight/panel0-backlight/"
APPS = "/home/etonedemid/.local/share/steam-arm/.local/share/Steam/steamapps"
MIN_BRIGHTNESS = 5
PRESETS = ("battery", "balanced", "performance", "max")
NOT_GAMES = re.compile(r"^(Proton|Steam Linux Runtime|Steamworks|FEX|Steam Controller)")


def read_table():
    table = {}
    try:
        with open(CONF) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and parts[1] in PRESETS:
                    table[parts[0]] = parts[1]
    except OSError:
        pass
    return table


def installed_games():
    found = []
    for path in glob.glob(APPS + "/appmanifest_*.acf"):
        with open(path, errors="replace") as f:
            text = f.read()
        appid, name = re.search(r'"appid"\s+"(\d+)"', text), re.search(r'"name"\s+"([^"]+)"', text)
        if appid and name and not NOT_GAMES.match(name.group(1)):
            found.append({"appid": appid.group(1), "name": name.group(1)})
    return sorted(found, key=lambda g: g["name"].lower())


def read_brightness():
    with open(BACKLIGHT + "brightness") as f:
        value = int(f.read())
    with open(BACKLIGHT + "max_brightness") as f:
        top = int(f.read())
    # Percent on a square curve: the panel's scale is linear and its top end is blinding.
    return round((value / top) ** 0.5 * 100)


class Plugin:
    async def get_state(self):
        return {"table": read_table(), "games": installed_games(), "brightness": read_brightness()}

    async def set_brightness(self, percent):
        percent = max(MIN_BRIGHTNESS, min(100, int(percent)))
        with open(BACKLIGHT + "max_brightness") as f:
            top = int(f.read())
        with open(BACKLIGHT + "brightness", "w") as f:
            f.write(str(round(top * (percent / 100) ** 2)))
        return True

    async def set_preset(self, appid, preset):
        appid = str(appid)
        if preset not in PRESETS or not (appid == "default" or appid.isdigit()):
            return False
        table = read_table()
        table[appid] = preset
        with open(CONF + ".tmp", "w") as f:
            for key, value in sorted(table.items()):
                f.write("%s %s\n" % (key, value))
        os.replace(CONF + ".tmp", CONF)
        return True

    async def reboot_android(self):
        os.makedirs(os.path.dirname(REBOOT_REQUEST), exist_ok=True)
        open(REBOOT_REQUEST, "w").close()
        return True

    async def _main(self):
        pass
