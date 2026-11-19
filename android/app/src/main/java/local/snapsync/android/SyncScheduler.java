package local.snapsync.android;

import android.content.Context;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;

import androidx.lifecycle.LiveData;
import androidx.work.BackoffPolicy;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.ExistingPeriodicWorkPolicy;
import androidx.work.ExistingWorkPolicy;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.PeriodicWorkRequest;
import androidx.work.WorkInfo;
import androidx.work.WorkManager;

import java.util.List;
import java.util.concurrent.TimeUnit;

final class SyncScheduler {
    static final String MANUAL = "manual";
    static final String GENERATION = "generation";
    private static final String PERIODIC_WORK = "sync-periodic";
    private static final String FOREGROUND_WORK = "sync-foreground";
    private static final String MANUAL_WORK = "sync-manual";

    static void cancelAll(Context context) {
        WorkManager manager = WorkManager.getInstance(context);
        manager.cancelUniqueWork(MANUAL_WORK);
        cancelAutomatic(manager);
    }

    static void configure(Context context, SyncSettings.Pairing pairing) {
        if (!pairing.canSync(true)) {
            cancelAll(context);
            return;
        }
        WorkManager manager = WorkManager.getInstance(context);
        if (!pairing.canSync(false)) {
            cancelAutomatic(manager);
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
            .setInputData(input(pairing, false))
            .setConstraints(constraints)
            .setInitialDelay(15, TimeUnit.MINUTES)
            .build();
        manager.enqueueUniquePeriodicWork(PERIODIC_WORK, ExistingPeriodicWorkPolicy.UPDATE, request);
    }

    static void sync(Context context, SyncSettings.Pairing pairing, boolean manual) {
        if (!pairing.canSync(manual)) {
            return;
        }
        OneTimeWorkRequest request = new OneTimeWorkRequest.Builder(ScreenshotWorker.class)
            .setInputData(input(pairing, manual))
            .setBackoffCriteria(BackoffPolicy.LINEAR, 15, TimeUnit.SECONDS)
            .build();
        WorkManager.getInstance(context).enqueueUniqueWork(
            manual ? MANUAL_WORK : FOREGROUND_WORK,
            manual ? ExistingWorkPolicy.REPLACE : ExistingWorkPolicy.APPEND_OR_REPLACE,
            request
        );
    }

    static LiveData<List<WorkInfo>> manualWork(Context context) {
        return WorkManager.getInstance(context).getWorkInfosForUniqueWorkLiveData(MANUAL_WORK);
    }

    private static Data input(SyncSettings.Pairing pairing, boolean manual) {
        return new Data.Builder().putBoolean(MANUAL, manual).putString(GENERATION, pairing.generation()).build();
    }

    private static void cancelAutomatic(WorkManager manager) {
        manager.cancelUniqueWork(PERIODIC_WORK);
        manager.cancelUniqueWork(FOREGROUND_WORK);
    }

    private SyncScheduler() {}
}
