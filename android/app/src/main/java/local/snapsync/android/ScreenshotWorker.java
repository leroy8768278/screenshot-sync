package local.snapsync.android;

import android.content.Context;

import androidx.annotation.NonNull;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

public final class ScreenshotWorker extends Worker {
    private volatile ScreenshotScan activeScan;

    public ScreenshotWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    @NonNull
    @Override
    public Result doWork() {
        Context context = getApplicationContext();
        SyncSettings.Pairing pairing = SyncSettings.read(context);
        String generation = getInputData().getString(SyncScheduler.GENERATION);
        if (!pairing.generation().equals(generation) || getInputData().getBoolean("manual", false)) {
            return Result.success();
        }

        try (ScreenshotScan scan = new ScreenshotScan(context, pairing)) {
            activeScan = scan;
            if (isStopped()) {
                return Result.success();
            }
            return switch (scan.run()) {
                case COMPLETE -> Result.success();
                case RETRY -> Result.retry();
                case TRANSIENT_FAILURE -> getRunAttemptCount() < 2 ? Result.retry() : Result.success();
            };
        } finally {
            activeScan = null;
        }
    }

    @Override
    public void onStopped() {
        ScreenshotScan scan = activeScan;
        if (scan != null) {
            scan.close();
        }
    }
}
