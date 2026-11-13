# pa2q Manager

Android app for postmarketOS on the Galaxy S25+, in the spirit of WOA Helper.
Needs root (grant it in ReSukiSU).

- **Boot postmarketOS**: backs up Android's boot images, checks pmOS's, writes
  and verifies them, reboots. Also a quick settings tile and a launcher
  shortcut; all of them ask first.
- **Backups**: `/data/adb/pa2q-manager/backups/`, kept if the app is removed. A
  new one is only made when the boot images changed.
- **Install a pmOS image file**: replaces pmOS's boot, vendor_boot or dtbo image;
  the old one stays as `.prev`.
- **pmOS storage**: mount at `/mnt/pmosroot`, boot logs, clear failed boots.

What it refuses: another phone model, a file that is not that kind of image or
does not fit, a half-Android half-pmOS boot chain. If a write fails it puts the
backup back and does not reboot.

All partition work is in [`assets/pa2qctl.sh`](assets/pa2qctl.sh); the Java only
draws buttons. It reboots through `sys.powerctl` with a forced reset as a backstop,
because the normal reboot can be a soft one here, which wouldn't load the new
kernel. It also keeps pmOS's copy of Android's boot images current, so
`boot-switch android` can't undo an OTA or a re-root.

```
sh build.sh              # out/pa2q-manager.apk: Android SDK, clang and a JDK, no Gradle
sh test-pa2qctl.sh       # the script against files standing in for partitions
adb install out/pa2q-manager.apk
```

The tests run on a desktop shell, not on Android's toybox and mksh. Before
trusting a changed script on the phone, try Refresh and Back up first: they
don't write to any partition.
