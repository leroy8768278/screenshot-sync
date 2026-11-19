package local.snapsync.android;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.os.CancellationSignal;
import android.os.OperationCanceledException;
import android.os.SystemClock;

import androidx.annotation.NonNull;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;

public final class ScreenshotWorker extends Worker {
    private static final ReentrantLock SYNC_LOCK = new ReentrantLock();
    private static final long MAX_RUN_MILLIS = TimeUnit.MINUTES.toMillis(7);
    private final CancellationSignal readCancellation = new CancellationSignal();
    private volatile ReceiverConnection activeReceiver;

    public ScreenshotWorker(@NonNull Context context, @NonNull WorkerParameters params) {
        super(context, params);
    }

    @NonNull
    @Override
    public Result doWork() {
        Context context = getApplicationContext();
        SyncSettings.Pairing pairing = SyncSettings.read(context);
        boolean manual = getInputData().getBoolean(SyncScheduler.MANUAL, false);
        // Jobs already scheduled by the previous version have no generation.
        String generation = getInputData().getString(SyncScheduler.GENERATION);
        if (!pairing.canSync(manual) || (generation != null && !generation.equals(pairing.generation()))
            || PhotoAccess.current(context) == PhotoAccess.NONE) {
            return Result.success();
        }
        if (!SYNC_LOCK.tryLock()) {
            return Result.retry();
        }
        try {
            return runSync(context, pairing);
        } finally {
            SYNC_LOCK.unlock();
        }
    }

    @Override
    public void onStopped() {
        ReceiverConnection receiver = activeReceiver;
        if (receiver != null) {
            receiver.close();
        }
        readCancellation.cancel();
    }

    private Result runSync(Context context, SyncSettings.Pairing pairing) {
        if (cancelled(context, pairing)) {
            return Result.success();
        }
        SyncSettings.status(context, pairing, R.string.status_scanning);
        ContentResolver resolver = context.getContentResolver();
        String receiverId = pairing.receiverId();
        long deadline = SystemClock.elapsedRealtime() + MAX_RUN_MILLIS;
        int uploaded = 0;
        int skipped = 0;

        ReceiverConnection receiver = null;
        try (DeliveryReceipts receipts = new DeliveryReceipts(context);
             Cursor cursor = ScreenshotCatalog.query(resolver, pairing, readCancellation)) {
            if (cursor == null) {
                SyncSettings.status(context, pairing, R.string.status_read_error);
                return retryThenWait();
            }

            while (cursor.moveToNext()) {
                if (cancelled(context, pairing)) {
                    return Result.success();
                }
                if (SystemClock.elapsedRealtime() >= deadline) {
                    return Result.retry();
                }
                ScreenshotCatalog.Screenshot screenshot = ScreenshotCatalog.read(cursor, pairing);
                if (screenshot == null || receipts.contains(receiverId, screenshot.id())) {
                    continue;
                }
                if (screenshot.type().isEmpty() || screenshot.size() > ReceiverConnection.MAX_BYTES) {
                    skipped++;
                    continue;
                }
                if (receiver == null) {
                    receiver = new ReceiverConnection(context, pairing.host(), pairing.code());
                    activeReceiver = receiver;
                    if (cancelled(context, pairing)) {
                        return Result.success();
                    }
                    int test = receiver.test();
                    if (test != 200) {
                        return serverError(context, pairing, test);
                    }
                }

                int response;
                try {
                    response = receiver.upload(resolver, screenshot, readCancellation,
                        () -> cancelled(context, pairing));
                } catch (FileNotFoundException missing) {
                    // A screenshot deleted while a scan was in progress is no longer eligible.
                    continue;
                }
                if (response == 200 || response == 201) {
                    receipts.remember(receiverId, screenshot.id());
                    uploaded++;
                } else if (response == 413 || response == 415 || response == 422) {
                    skipped++;
                } else {
                    return serverError(context, pairing, response);
                }
            }
        } catch (OperationCanceledException stopped) {
            return Result.success();
        } catch (SecurityException denied) {
            SyncSettings.status(context, pairing, R.string.status_read_error);
            return Result.success();
        } catch (IOException unavailable) {
            if (cancelled(context, pairing)) {
                return Result.success();
            }
            SyncSettings.status(context, pairing, R.string.status_network);
            return retryThenWait();
        } finally {
            if (receiver != null) {
                receiver.close();
                activeReceiver = null;
            }
        }

        if (skipped > 0) {
            SyncSettings.status(context, pairing, R.string.status_skipped, uploaded, skipped);
        } else if (uploaded > 0) {
            SyncSettings.status(context, pairing, R.string.status_done, uploaded);
        } else {
            SyncSettings.status(context, pairing, R.string.status_no_changes);
        }
        return Result.success();
    }

    private Result serverError(Context context, SyncSettings.Pairing pairing, int response) {
        if (response == 401 || response == 403) {
            SyncSettings.status(context, pairing, R.string.status_bad_code);
            return Result.success();
        }
        SyncSettings.status(context, pairing, R.string.status_rejected, response);
        return response >= 500 || response == 429 ? retryThenWait() : Result.success();
    }

    private boolean cancelled(Context context, SyncSettings.Pairing pairing) {
        return isStopped() || !SyncSettings.isCurrent(context, pairing);
    }

    private Result retryThenWait() {
        return getRunAttemptCount() < 2 ? Result.retry() : Result.success();
    }
}
