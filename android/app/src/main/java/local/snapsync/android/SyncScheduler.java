package local.snapsync.android;

import android.content.Context;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;

import androidx.work.BackoffPolicy;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkManager;

import java.util.concurrent.TimeUnit;

final class SyncScheduler {
    static final String MANUAL = "manual";
    private static final String PERIODIC_WORK = "sync-periodic";
    private static final String FOREGROUND_WORK = "sync-foreground";
    private static final String MANUAL_WORK = "sync-manual";

    static void configure(Context context, SyncSettings.Pairing pairing) {
        WorkManager manager = WorkManager.getInstance(context);
        if (!pairing.isConfigured() || !pairing.automatic()) {
            manager.cancelUniqueWork(PERIODIC_WORK);
            manager.cancelUniqueWork(FOREGROUND_WORK);
            return;
        }

        NetworkRequest lan = new NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .build();
        Constraints constraints = new Constraints.Builder()
            .setRequiredNetworkRequest(lan, NetworkType.CONNECTED)
            .build();
        PeriodicWorkRequest request = new PeriodicWorkRequest.Builder(
            ScreenshotWorker.class, 15, TimeUnit.MINUTES)
            .setConstraints(constraints)
            .setInitialDelay(15, TimeUnit.MINUTES)
            .build();
        manager.enqueueUniquePeriodicWork(PERIODIC_WORK, ExistingPeriodicWorkPolicy.KEEP, request);
    }

    static void sync(Context context, boolean manual) {
        OneTimeWorkRequest request = new OneTimeWorkRequest.Builder(ScreenshotWorker.class)
            .setInputData(new Data.Builder().putBoolean(MANUAL, manual).build())
            .setBackoffCriteria(BackoffPolicy.LINEAR, 15, TimeUnit.SECONDS)
            .build();
        WorkManager.getInstance(context).enqueueUniqueWork(
            manual ? MANUAL_WORK : FOREGROUND_WORK,
            manual ? ExistingWorkPolicy.REPLACE : ExistingWorkPolicy.APPEND_OR_REPLACE,
            request
        );
    }

    private SyncScheduler() {}
}
