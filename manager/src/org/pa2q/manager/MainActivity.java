package org.pa2q.manager;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

/**
 * WOA Helper style manager for postmarketOS on the Galaxy S25+. All partition
 * work is in assets/pa2qctl.sh, run through su; this class draws the buttons,
 * asks before anything dangerous and shows the script's output.
 */
public class MainActivity extends Activity {
    static final String ACTION_BOOT = "org.pa2q.manager.BOOT";

    private static final String DATA = "/data/adb/pa2q-manager";
    private static final String CTL = DATA + "/bin/pa2qctl.sh";
    private static final int PICK_IMAGE = 1;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private final List<Button> buttons = new ArrayList<>();
    private final Map<String, TextView> rows = new HashMap<>();
    private final Map<String, String> status = new HashMap<>();

    private String suFlags;
    private boolean busy;
    private boolean bootRequested;
    private String pickedSlot;
    private LinearLayout page;
    private ProgressBar progress;
    private TextView console;
    private ScrollView consoleScroll;
    private Button mountButton;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        buildUi();
        bootRequested = ACTION_BOOT.equals(getIntent().getAction());
        startup();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (ACTION_BOOT.equals(intent.getAction())) {
            if (suFlags != null && !busy) confirmBoot();
            else bootRequested = true;
        }
    }

    // ---------------------------------------------------------------- layout

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private void buildUi() {
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.BLACK);
        scroll.setFitsSystemWindows(true);
        page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setPadding(dp(16), dp(16), dp(16), dp(24));
        scroll.addView(page);

        TextView title = new TextView(this);
        title.setText("pa2q Manager");
        title.setTextColor(Color.WHITE);
        title.setTextSize(28);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        page.addView(title);

        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progress.setIndeterminate(true);
        progress.setVisibility(View.INVISIBLE);
        page.addView(progress);

        LinearLayout card = card();
        row(card, "Device", "model");
        row(card, "Kernel", "kernel");
        row(card, "Boot chain", "chain");
        row(card, "pmOS kernel", "pmos_kernel");
        row(card, "pmOS storage", "rootfs");
        row(card, "Failed pmOS boots", "fails");
        row(card, "Way back to Android", "return_images");
        row(card, "Backups", "backups");
        page.addView(card);

        Button boot = button("Boot postmarketOS", v -> confirmBoot());
        boot.setBackground(outline(Color.WHITE, Color.WHITE));
        boot.setTextColor(Color.BLACK);
        boot.setTextSize(18);
        boot.setMinHeight(dp(64));
        page.addView(boot, spaced());

        section("Boot images");
        page.addView(button("Check images", v -> run(null, "check")), spaced());
        page.addView(button("Back up boot images", v -> run(null, "backup")), spaced());
        page.addView(button("Restore a backup", v -> chooseBackup()), spaced());
        page.addView(button("Install a pmOS image file", v -> chooseSlot()), spaced());

        section("pmOS storage");
        mountButton = button("Mount pmOS", v -> toggleMount());
        page.addView(mountButton, spaced());
        page.addView(button("Boot log", v -> run(null, "bootlog")), spaced());
        page.addView(button("Previous boot log", v -> run(null, "bootlog", "prev")), spaced());
        page.addView(button("Clear failed boots", v -> run(null, "reset-fails")), spaced());

        section("Phone");
        page.addView(button("Refresh", v -> refresh()), spaced());
        page.addView(button("Reboot", v -> confirm("Reboot the phone?", "", "Reboot",
                () -> run(null, "reboot"))), spaced());

        section("Output");
        console = new TextView(this);
        console.setTextColor(Color.LTGRAY);
        console.setTextSize(11);
        console.setTypeface(Typeface.MONOSPACE);
        console.setTextIsSelectable(true);
        console.setPadding(dp(12), dp(12), dp(12), dp(12));
        consoleScroll = new ScrollView(this);
        consoleScroll.setBackground(outline(Color.BLACK, 0xFF333333));
        consoleScroll.addView(console);
        // the page scrolls too; let the output keep its own drags
        consoleScroll.setOnTouchListener((v, e) -> {
            v.getParent().requestDisallowInterceptTouchEvent(true);
            return false;
        });
        page.addView(consoleScroll, new LinearLayout.LayoutParams(-1, dp(260)));

        setContentView(scroll);
        setBusy(true);
    }

    private GradientDrawable outline(int fill, int stroke) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fill);
        d.setStroke(dp(1), stroke);
        d.setCornerRadius(dp(12));
        return d;
    }

    private LinearLayout card() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(16), dp(10), dp(16), dp(10));
        c.setBackground(outline(Color.BLACK, 0xFF333333));
        return c;
    }

    private void row(LinearLayout card, String label, String key) {
        LinearLayout r = new LinearLayout(this);
        r.setPadding(0, dp(5), 0, dp(5));
        TextView l = new TextView(this);
        l.setText(label);
        l.setTextColor(0xFF999999);
        l.setTextSize(14);
        r.addView(l, new LinearLayout.LayoutParams(0, -2, 1));
        TextView v = new TextView(this);
        v.setText("...");
        v.setTextColor(Color.WHITE);
        v.setTextSize(14);
        v.setGravity(Gravity.END);
        r.addView(v, new LinearLayout.LayoutParams(0, -2, 1.4f));
        rows.put(key, v);
        card.addView(r);
    }

    private Button button(String text, View.OnClickListener click) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(Color.WHITE);
        b.setTextSize(15);
        b.setBackground(outline(Color.BLACK, 0xFF666666));
        b.setStateListAnimator(null);
        b.setOnClickListener(click);
        buttons.add(b);
        return b;
    }

    private LinearLayout.LayoutParams spaced() {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2);
        p.topMargin = dp(10);
        return p;
    }

    private void section(String name) {
        TextView t = new TextView(this);
        t.setText(name);
        t.setTextColor(Color.WHITE);
        t.setTextSize(16);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(0, dp(24), 0, 0);
        page.addView(t);
    }

    private void setBusy(boolean on) {
        busy = on;
        for (Button b : buttons) {
            b.setEnabled(!on);
            b.setAlpha(on ? 0.4f : 1f);
        }
        progress.setVisibility(on ? View.VISIBLE : View.INVISIBLE);
        // a flash must not race the screen timeout and a sleepy user
        if (on) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    private void log(String line) {
        console.append(line + "\n");
        // not fullScroll: it moves focus, and the whole page jumps down with it
        consoleScroll.post(() -> consoleScroll.scrollTo(0, console.getHeight()));
    }

    // ------------------------------------------------------------------ root

    private static int exec(List<String> cmd, Consumer<String> out) {
        try {
            Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            p.getOutputStream().close();
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                for (String s; (s = r.readLine()) != null; ) out.accept(s);
            }
            return p.waitFor();
        } catch (IOException | InterruptedException e) {
            out.accept(e.toString());
            return -1;
        }
    }

    private static boolean isRoot(List<String> su) {
        StringBuilder b = new StringBuilder();
        List<String> c = new ArrayList<>(su);
        c.add("-c");
        c.add("id -u");
        return exec(c, b::append) == 0 && b.toString().trim().equals("0");
    }

    /** su with the global mount namespace if it can, so a mount outlives the command. */
    private void startup() {
        new Thread(() -> {
            List<String> su = new ArrayList<>(List.of("su", "--mount-master"));
            if (!isRoot(su)) su = new ArrayList<>(List.of("su"));
            if (!isRoot(su)) {
                ui.post(() -> {
                    setBusy(false);
                    for (Button b : buttons) {
                        b.setEnabled(false);
                        b.setAlpha(0.4f);
                    }
                    log("No root. Open your root manager (ReSukiSU), grant root to");
                    log("pa2q Manager, then open this app again.");
                    new AlertDialog.Builder(this).setTitle("Root is needed")
                            .setMessage("Grant root to pa2q Manager in your root manager, then reopen this app.")
                            .setPositiveButton("OK", null).show();
                });
                return;
            }
            String flags = String.join(" ", su);
            String err = installBackend(flags);
            ui.post(() -> {
                if (err != null) {
                    setBusy(false);
                    log("Cannot install the backend: " + err);
                    return;
                }
                suFlags = flags;
                refresh();
            });
        }).start();
    }

    /** Backend goes where root can run it and uninstalling the app leaves the backups. */
    private String installBackend(String su) {
        try {
            File dir = new File(getCacheDir(), "bin");
            dir.mkdirs();
            for (String name : new String[] {"pa2qctl.sh", "loopcfg"}) {
                try (InputStream in = getAssets().open(name);
                     OutputStream o = new FileOutputStream(new File(dir, name))) {
                    in.transferTo(o);
                }
            }
            String d = dir.getAbsolutePath();
            StringBuilder out = new StringBuilder();
            int rc = exec(suCmd(su, "mkdir -p " + DATA + "/bin && cp " + d + "/pa2qctl.sh " + d
                    + "/loopcfg " + DATA + "/bin/ && chmod 700 " + DATA + "/bin/*"), out::append);
            return rc == 0 ? null : out.toString();
        } catch (IOException e) {
            return e.toString();
        }
    }

    private static List<String> suCmd(String su, String script) {
        List<String> c = new ArrayList<>(List.of(su.split(" ")));
        c.add("-c");
        c.add(script);
        return c;
    }

    private static String quote(String s) {
        return "'" + s.replace("'", "'\\''") + "'";
    }

    /** One command at a time; done may be null. Refreshes the dashboard afterwards. */
    private void run(Consumer<Integer> done, String... args) {
        if (busy) return;
        setBusy(true);
        StringBuilder script = new StringBuilder("sh " + CTL);
        for (String a : args) script.append(' ').append(quote(a));
        log("$ " + String.join(" ", args));
        new Thread(() -> {
            int rc = exec(suCmd(suFlags, script.toString()), s -> ui.post(() -> log(s)));
            ui.post(() -> {
                if (rc != 0) log("Failed (exit " + rc + ")");
                setBusy(false);
                if (done != null) done.accept(rc);
                else refresh();
            });
        }).start();
    }

    private void refresh() {
        busy = false;
        setBusy(true);
        status.clear();
        new Thread(() -> {
            StringBuilder err = new StringBuilder();
            int rc = exec(suCmd(suFlags, "sh " + CTL + " status"), s -> {
                int i = s.indexOf('=');
                if (i > 0 && !s.startsWith("ERROR")) status.put(s.substring(0, i), s.substring(i + 1));
                else err.append(s).append('\n');
            });
            ui.post(() -> {
                if (rc != 0 && err.length() > 0) log(err.toString().trim());
                showStatus();
                setBusy(false);
                if (bootRequested) {
                    bootRequested = false;
                    confirmBoot();
                }
            });
        }).start();
    }

    private void showStatus() {
        for (Map.Entry<String, TextView> e : rows.entrySet()) {
            String v = status.get(e.getKey());
            e.getValue().setText(v == null || v.isEmpty() ? "-" : v);
        }
        String chain = status.getOrDefault("chain", "");
        rows.get("chain").setText(switch (chain) {
            case "android" -> "Android";
            case "pmos" -> "postmarketOS (next reboot)";
            case "mixed" -> "MIXED, restore a backup";
            case "unknown" -> "pmOS images missing";
            default -> "-";
        });
        rows.get("return_images").setText("yes".equals(status.get("return_images")) ? "Ready" : "Made on first boot");
        mountButton.setText("yes".equals(status.get("mounted")) ? "Unmount pmOS" : "Mount pmOS");
    }

    // --------------------------------------------------------------- actions

    private void confirm(String title, String message, String yes, Runnable action) {
        new AlertDialog.Builder(this).setTitle(title).setMessage(message)
                .setPositiveButton(yes, (d, w) -> action.run())
                .setNegativeButton("Cancel", null).show();
    }

    private void confirmBoot() {
        String chain = status.getOrDefault("chain", "");
        if ("mixed".equals(chain) || "unknown".equals(chain) || chain.isEmpty()) {
            new AlertDialog.Builder(this).setTitle("Cannot boot postmarketOS")
                    .setMessage("mixed".equals(chain)
                            ? "The boot partitions are half Android, half pmOS. Restore a backup first."
                            : "The pmOS images could not be read. See Output.")
                    .setPositiveButton("OK", null).show();
            return;
        }
        confirm("Boot postmarketOS?",
                "Backs up Android's boot images, writes pmOS's and reboots now. Save your work first.\n\n"
                        + "To come back: the Switch to Android icon in Plasma, or hold Volume Up during boot.",
                "Boot", () -> run(null, "switch"));
    }

    private void toggleMount() {
        run(null, "yes".equals(status.get("mounted")) ? "umount" : "mount");
    }

    private void chooseBackup() {
        List<String> names = new ArrayList<>();
        setBusy(true);
        new Thread(() -> {
            exec(suCmd(suFlags, "sh " + CTL + " backups"), names::add);
            ui.post(() -> {
                setBusy(false);
                if (names.isEmpty()) {
                    log("No backups yet.");
                    return;
                }
                new AlertDialog.Builder(this).setTitle("Restore which backup?")
                        .setItems(names.toArray(new String[0]), (d, i) -> confirm(
                                "Restore " + names.get(i) + "?",
                                "Overwrites boot, vendor_boot and dtbo with this backup. "
                                        + "It takes effect on the next reboot.",
                                "Restore", () -> run(null, "restore", names.get(i))))
                        .setNegativeButton("Cancel", null).show();
            });
        }).start();
    }

    private void chooseSlot() {
        String[] slots = {"boot", "vendor_boot", "dtbo"};
        new AlertDialog.Builder(this).setTitle("Which pmOS image?")
                .setItems(slots, (d, i) -> {
                    pickedSlot = slots[i];
                    Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                    pick.addCategory(Intent.CATEGORY_OPENABLE);
                    pick.setType("*/*");
                    startActivityForResult(pick, PICK_IMAGE);
                })
                .setNegativeButton("Cancel", null).show();
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != PICK_IMAGE || result != RESULT_OK || data == null) return;
        Uri uri = data.getData();
        String slot = pickedSlot;
        File tmp = new File(getCacheDir(), "picked.img");
        setBusy(true);
        log("Reading the picked file ...");
        new Thread(() -> {
            try (InputStream in = getContentResolver().openInputStream(uri);
                 OutputStream o = new FileOutputStream(tmp)) {
                in.transferTo(o);
            } catch (IOException | NullPointerException e) {
                ui.post(() -> {
                    log("Cannot read it: " + e);
                    setBusy(false);
                });
                return;
            }
            ui.post(() -> {
                setBusy(false);
                run(rc -> {
                    tmp.delete();
                    refresh();
                }, "install", slot, tmp.getAbsolutePath());
            });
        }).start();
    }
}
