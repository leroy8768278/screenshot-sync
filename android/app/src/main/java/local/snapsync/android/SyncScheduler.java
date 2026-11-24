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
    static final String GENERATION = "generation";
    private static final String PERIODIC_WORK = "sync-periodic";
    private static final String FOREGROUND_WORK = "sync-foreground";

    static void cancelLegacyScan(Context context) {
        WorkManager.getInstance(context).cancelUniqueWork("sync-manual");
    }

    static void configure(Context context, SyncSettings.Pairing pairing) {
        WorkManager manager = WorkManager.getInstance(context);
        if (!ScreenshotScan.canRun(context, pairing)) {
            cancelAutomatic(manager);
            return;
        }

        Constraints constraints = new Constraints.Builder()
            .setRequiredNetworkRequest(localNetwork(), NetworkType.CONNECTED)
            .build();
        PeriodicWorkRequest request = new PeriodicWorkRequest.Builder(
            ScreenshotWorker.class, 15, TimeUnit.MINUTES)
            .setInputData(input(pairing))
            .setConstraints(constraints)
            .setInitialDelay(15, TimeUnit.MINUTES)
            .build();
        manager.enqueueUniquePeriodicWork(PERIODIC_WORK, ExistingPeriodicWorkPolicy.UPDATE, request);
    }

    static void sync(Context context, SyncSettings.Pairing pairing) {
        if (!ScreenshotScan.canRun(context, pairing)) {
            return;
        }
        OneTimeWorkRequest request = new OneTimeWorkRequest.Builder(ScreenshotWorker.class)
            .setInputData(input(pairing))
            .setBackoffCriteria(BackoffPolicy.LINEAR, 15, TimeUnit.SECONDS)
            .build();
        WorkManager.getInstance(context).enqueueUniqueWork(
            FOREGROUND_WORK, ExistingWorkPolicy.APPEND_OR_REPLACE, request
        );
    }

    static NetworkRequest localNetwork() {
        return new NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .build();
    }

    private static Data input(SyncSettings.Pairing pairing) {
        return new Data.Builder().putString(GENERATION, pairing.generation()).build();
    }

    private static void cancelAutomatic(WorkManager manager) {
        manager.cancelUniqueWork(PERIODIC_WORK);
        manager.cancelUniqueWork(FOREGROUND_WORK);
    }

    private SyncScheduler() {}
}
