package local.snapsync.android;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.os.CancellationSignal;
import android.os.OperationCanceledException;
import android.os.SystemClock;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;

final class ScreenshotScan implements AutoCloseable {
    enum Outcome { COMPLETE, RETRY, TRANSIENT_FAILURE }

    private static final ReentrantLock SYNC_LOCK = new ReentrantLock();
    private static final long MAX_RUN_MILLIS = TimeUnit.MINUTES.toMillis(7);

    private final Context context;
    private final SyncSettings.Pairing pairing;
    private final CancellationSignal readCancellation = new CancellationSignal();
    private volatile ReceiverConnection activeReceiver;

    ScreenshotScan(Context context, SyncSettings.Pairing pairing) {
        this.context = context.getApplicationContext();
        this.pairing = pairing;
    }

    static boolean canRun(Context context, SyncSettings.Pairing pairing) {
        return pairing.canSync() && PhotoAccess.current(context) == PhotoAccess.FULL;
    }

    Outcome run() {
        if (cancelled() || !canRun(context, pairing)) {
            return Outcome.COMPLETE;
        }
        if (!SYNC_LOCK.tryLock()) {
            return Outcome.RETRY;
        }
        try {
            return runSync();
        } finally {
            SYNC_LOCK.unlock();
        }
    }

    @Override
    public void close() {
        readCancellation.cancel();
        ReceiverConnection receiver = activeReceiver;
        if (receiver != null) {
            receiver.close();
        }
    }

    private Outcome runSync() {
        if (cancelled()) {
            return Outcome.COMPLETE;
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
                return Outcome.TRANSIENT_FAILURE;
            }

            while (cursor.moveToNext()) {
                if (cancelled()) {
                    return Outcome.COMPLETE;
                }
                if (SystemClock.elapsedRealtime() >= deadline) {
                    return Outcome.RETRY;
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
                    if (cancelled()) {
                        return Outcome.COMPLETE;
                    }
                    int test = receiver.test().status();
                    if (test != 200) {
                        return serverError(test);
                    }
                }

                int response;
                try {
                    response = MediaTransfer.send(context, pairing, receiver, receipts, screenshot.uri(),
                        screenshot.id(), screenshot.filename(), screenshot.type(), readCancellation,
                        this::cancelled);
                } catch (FileNotFoundException missing) {
                    // A screenshot deleted while a scan was in progress is no longer eligible.
                    continue;
                }
                if (response == MediaTransfer.ALREADY_SENT) {
                    continue;
                }
                if (response == 200 || response == 201) {
                    uploaded++;
                } else if (response == 413 || response == 415 || response == 422) {
                    skipped++;
                } else {
                    return serverError(response);
                }
            }
        } catch (OperationCanceledException stopped) {
            return Outcome.COMPLETE;
        } catch (SecurityException denied) {
            SyncSettings.status(context, pairing, R.string.status_read_error);
            return Outcome.COMPLETE;
        } catch (IOException unavailable) {
            if (cancelled()) {
                return Outcome.COMPLETE;
            }
            SyncSettings.status(context, pairing, R.string.status_network);
            return Outcome.TRANSIENT_FAILURE;
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
        return Outcome.COMPLETE;
    }

    private Outcome serverError(int response) {
        if (response == 401 || response == 403) {
            SyncSettings.status(context, pairing, R.string.status_bad_code);
            return Outcome.COMPLETE;
        }
        SyncSettings.status(context, pairing, R.string.status_rejected, response);
        return response >= 500 || response == 429 ? Outcome.TRANSIENT_FAILURE : Outcome.COMPLETE;
    }

    private boolean cancelled() {
        return readCancellation.isCanceled() || !SyncSettings.isCurrent(context, pairing);
    }
}
