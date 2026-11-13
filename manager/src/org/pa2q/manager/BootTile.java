package org.pa2q.manager;

import android.app.PendingIntent;
import android.content.Intent;
import android.service.quicksettings.TileService;

/** Quick settings tile: opens the app on its "Boot postmarketOS?" question. */
public class BootTile extends TileService {
    @Override
    public void onClick() {
        Intent i = new Intent(this, MainActivity.class).setAction(MainActivity.ACTION_BOOT)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivityAndCollapse(PendingIntent.getActivity(this, 0, i,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
    }
}
