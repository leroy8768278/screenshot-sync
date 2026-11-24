package local.snapsync.android;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.OperationCanceledException;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.BooleanSupplier;

final class MediaTransfer {
    static final int ALREADY_SENT = -1;
    // A picker URI and a MediaStore item may refer to the same bytes. Serialize the
    // receipt check and upload so both send paths cannot commit it at the same time.
    private static final ReentrantLock IMAGE_DELIVERY = new ReentrantLock(true);
    // A long manual video upload can run alongside live screenshot sync.
    private static final ReentrantLock VIDEO_DELIVERY = new ReentrantLock(true);

    static int send(Context context, SyncSettings.Pairing pairing, ReceiverConnection receiver,
                    DeliveryReceipts receipts, Uri uri, String screenshotId, String filename,
                    String type, CancellationSignal readCancellation, BooleanSupplier cancelled) throws IOException {
        boolean video = type.startsWith("video/");
        long maxBytes = video ? ReceiverConnection.MAX_VIDEO_BYTES : ReceiverConnection.MAX_BYTES;
        ReentrantLock delivery = video ? VIDEO_DELIVERY : IMAGE_DELIVERY;
        Path staged = Files.createTempFile(context.getCacheDir().toPath(), "selected-media-", ".tmp");
        try {
            String contentId = stage(context, uri, pairing, readCancellation, cancelled, staged, maxBytes);
            if (contentId == null) {
                return 413;
            }
            while (!tryLock(delivery)) {
                checkCancelled(cancelled);
            }
            try {
                checkCancelled(cancelled);
                String receiverId = pairing.receiverId();
                String manualReceipt = "manual:" + contentId;
                String automaticReceipt = "automatic:" + contentId;
                if (receipts.contains(receiverId, manualReceipt)
                    || (screenshotId == null && receipts.contains(receiverId, automaticReceipt))) {
                    if (screenshotId != null) {
                        receipts.remember(receiverId, screenshotId);
                    }
                    return ALREADY_SENT;
                }
                String id = screenshotId == null ? contentId : screenshotId;
                int status;
                try (InputStream input = Files.newInputStream(staged)) {
                    status = receiver.upload(input, Files.size(staged), id, pairing.deviceId(), filename, type, cancelled);
                }
                if (status == 200 || status == 201) {
                    if (screenshotId == null) {
                        receipts.remember(receiverId, manualReceipt);
                    } else {
                        receipts.remember(receiverId, screenshotId, automaticReceipt);
                    }
                }
                return status;
            } finally {
                delivery.unlock();
            }
        } finally {
            Files.deleteIfExists(staged);
        }
    }

    private static String stage(Context context, Uri uri, SyncSettings.Pairing pairing,
                                CancellationSignal readCancellation, BooleanSupplier cancelled,
                                Path staged, long maxBytes) throws IOException {
        checkCancelled(cancelled);
        AssetFileDescriptor descriptor = context.getContentResolver().openAssetFileDescriptor(uri, "r", readCancellation);
        if (descriptor == null) {
            throw new FileNotFoundException("Media is no longer available");
        }
        MessageDigest digest = sha256();
        try (descriptor) {
            if (descriptor.getLength() > maxBytes) {
                return null;
            }
            long length = 0;
            try (InputStream input = descriptor.createInputStream(); OutputStream output = Files.newOutputStream(staged)) {
                byte[] buffer = new byte[64 * 1024];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    checkCancelled(cancelled);
                    length += count;
                    if (length > maxBytes) {
                        return null;
                    }
                    digest.update(buffer, 0, count);
                    output.write(buffer, 0, count);
                }
            }
            if (length == 0) {
                throw new FileNotFoundException("Empty media");
            }
        }
        return "android-" + SyncSettings.digest(pairing.installation() + ":content:" + SyncSettings.bytesToHex(digest.digest()));
    }

    private static MessageDigest sha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException failure) {
            throw new IllegalStateException("SHA-256 unavailable", failure);
        }
    }

    private static boolean tryLock(ReentrantLock delivery) {
        try {
            return delivery.tryLock(100, TimeUnit.MILLISECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new OperationCanceledException();
        }
    }

    static void checkCancelled(BooleanSupplier cancelled) {
        if (cancelled.getAsBoolean()) {
            throw new OperationCanceledException();
        }
    }

    private MediaTransfer() {}
}
