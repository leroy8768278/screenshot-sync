package local.snapsync.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.database.ContentObserver;
import android.net.ConnectivityManager;
import android.net.Network;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** The explicitly enabled live link to the paired Mac, independent of the activity lifecycle. */
public final class ScreenshotMonitor extends Service {
    private static final String STOP = "local.snapsync.android.STOP_LIVE_SYNC";
    private static final String CHANNEL = "live_sync";
    private static final int NOTIFICATION_ID = 701;
    private static final long CHANGE_DELAY = 100;
    private static final long INITIAL_RETRY_DELAY = 1_000;
    private static final long MAX_RETRY_DELAY = 30_000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Runnable scanPending = this::scan;
    private final ContentObserver photos = new ContentObserver(handler) {
        @Override
        public void onChange(boolean selfChange) {
            scheduleScan(CHANGE_DELAY);
        }
    };
    private final ConnectivityManager.NetworkCallback network = new ConnectivityManager.NetworkCallback() {
        @Override
        public void onAvailable(Network available) {
            retryDelay = INITIAL_RETRY_DELAY;
            scheduleScan(CHANGE_DELAY);
        }
    };
    private final SharedPreferences.OnSharedPreferenceChangeListener settings = (preferences, key) -> {
        if (SyncSettings.LIVE_ENABLED.equals(key) || SyncScheduler.GENERATION.equals(key)) {
            verifySettings();
        }
    };

    private boolean listening;
    private boolean networkRequested;
    private boolean rescan;
    private long retryDelay = INITIAL_RETRY_DELAY;
    private ScreenshotScan activeScan;

    static boolean start(Context context, SyncSettings.Pairing pairing) {
        if (!canListen(context, pairing)) {
            stop(context);
            return false;
        }
        try {
            context.startForegroundService(new Intent(context, ScreenshotMonitor.class));
            return true;
        } catch (IllegalStateException | SecurityException unavailable) {
            SyncSettings.status(context, pairing, R.string.live_start_failed);
            return false;
        }
    }

    static void stop(Context context) {
        context.stopService(new Intent(context, ScreenshotMonitor.class));
    }

    private static boolean canListen(Context context, SyncSettings.Pairing pairing) {
        return SyncSettings.liveEnabled(context) && ScreenshotScan.canRun(context, pairing);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) {
            SyncSettings.setLiveEnabled(this, false);
        }
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (!canListen(this, pairing)) {
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        try {
            if (!listening) {
                startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
                getContentResolver().registerContentObserver(ScreenshotCatalog.IMAGES, true, photos);
                listening = true;
                SyncSettings.preferences(this).registerOnSharedPreferenceChangeListener(settings);
                ConnectivityManager manager = getSystemService(ConnectivityManager.class);
                manager.requestNetwork(SyncScheduler.localNetwork(), network, handler);
                networkRequested = true;
            }
            scheduleScan(0);
        } catch (IllegalStateException | SecurityException unavailable) {
            SyncSettings.status(this, pairing, R.string.live_start_failed);
            stopSelf(startId);
        }
        return START_NOT_STICKY;
    }

    private Notification notification() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL, getString(R.string.live_notification_channel),
            NotificationManager.IMPORTANCE_LOW));
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        PendingIntent open = PendingIntent.getActivity(this, 1,
            new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags);
        PendingIntent stop = PendingIntent.getService(this, 2,
            new Intent(this, ScreenshotMonitor.class).setAction(STOP), flags);
        Notification.Builder builder = new Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(getString(R.string.live_notification_title))
            .setContentText(getString(R.string.live_notification_text))
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(new Notification.Action.Builder(null, getString(R.string.live_stop), stop).build());
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        }
        return builder.build();
    }

    private void verifySettings() {
        if (!canListen(this, SyncSettings.read(this))) {
            stopSelf();
            return;
        }
        if (activeScan != null) {
            activeScan.close();
        }
        scheduleScan(0);
    }

    private void scheduleScan(long delay) {
        if (listening) {
            handler.removeCallbacks(scanPending);
            handler.postDelayed(scanPending, delay);
        }
    }

    private void scan() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (!canListen(this, pairing)) {
            stopSelf();
            return;
        }
        if (activeScan != null) {
            rescan = true;
            return;
        }
        ScreenshotScan scan = new ScreenshotScan(this, pairing);
        activeScan = scan;
        executor.execute(() -> {
            ScreenshotScan.Outcome result;
            try (scan) {
                result = scan.run();
            }
            handler.post(() -> finishScan(scan, result));
        });
    }

    private void finishScan(ScreenshotScan scan, ScreenshotScan.Outcome result) {
        if (activeScan != scan || !listening) {
            return;
        }
        activeScan = null;
        if (rescan) {
            rescan = false;
            scheduleScan(0);
        } else if (result != ScreenshotScan.Outcome.COMPLETE) {
            scheduleScan(retryDelay);
            retryDelay = Math.min(retryDelay * 2, MAX_RETRY_DELAY);
        } else {
            retryDelay = INITIAL_RETRY_DELAY;
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (listening) {
            listening = false;
            getContentResolver().unregisterContentObserver(photos);
            SyncSettings.preferences(this).unregisterOnSharedPreferenceChangeListener(settings);
        }
        if (networkRequested) {
            getSystemService(ConnectivityManager.class).unregisterNetworkCallback(network);
        }
        if (activeScan != null) {
            activeScan.close();
            activeScan = null;
        }
        executor.shutdownNow();
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }
}
