package local.snapsync.android;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.OperationCanceledException;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

final class ManualSend implements AutoCloseable {
    record Result(List<Uri> pending, int sent, int alreadySynced, int error, int response) {}

    private final CancellationSignal cancellation = new CancellationSignal();
    private ReceiverConnection receiver;
    private volatile boolean cancelled;

    Result send(Context context, SyncSettings.Pairing pairing, List<Uri> selected) {
        ArrayList<Uri> pending = new ArrayList<>(selected);
        int sent = 0;
        int duplicates = 0;
        int error = 0;
        int response = 0;
        try (ReceiverConnection connection = new ReceiverConnection(context, pairing.host(), pairing.code());
             DeliveryReceipts receipts = new DeliveryReceipts(context)) {
            synchronized (this) {
                MediaTransfer.checkCancelled(() -> cancelled);
                receiver = connection;
            }
            MediaTransfer.checkCancelled(() -> cancelled(context, pairing));
            response = connection.test().status();
            if (response != 200) {
                return new Result(pending, sent, duplicates, responseError(response), response);
            }
            ContentResolver resolver = context.getContentResolver();
            for (Uri uri : selected) {
                MediaTransfer.checkCancelled(() -> cancelled(context, pairing));
                String name;
                String type;
                try {
                    name = displayName(resolver, uri);
                    type = type(resolver, uri, name);
                } catch (SecurityException | IllegalArgumentException unavailable) {
                    error = R.string.manual_unreadable;
                    continue;
                }
                String extension = extension(type);
                if (extension.isEmpty()) {
                    error = R.string.manual_unsupported;
                    continue;
                }
                try {
                    int status = MediaTransfer.send(context, pairing, connection, receipts, uri, null,
                        ScreenshotCatalog.filename(name, 0, 0, extension), type, cancellation,
                        () -> cancelled(context, pairing));
                    if (status == 200 || status == 201 || status == MediaTransfer.ALREADY_SENT) {
                        pending.remove(uri);
                        if (status == MediaTransfer.ALREADY_SENT || status == 200) {
                            duplicates++;
                        } else {
                            sent++;
                        }
                    } else if (status == 413 || status == 415 || status == 422) {
                        error = R.string.manual_unsupported;
                    } else {
                        response = status;
                        error = responseError(status);
                        break;
                    }
                } catch (FileNotFoundException | SecurityException | IllegalArgumentException unavailable) {
                    error = R.string.manual_unreadable;
                }
            }
        } catch (OperationCanceledException stopped) {
            error = R.string.manual_cancelled;
        } catch (IOException unavailable) {
            error = cancelled(context, pairing) ? R.string.manual_cancelled : R.string.status_network;
        } finally {
            synchronized (this) {
                receiver = null;
            }
        }
        return new Result(pending, sent, duplicates, error, response);
    }

    @Override
    public void close() {
        ReceiverConnection connection;
        synchronized (this) {
            cancelled = true;
            connection = receiver;
        }
        cancellation.cancel();
        if (connection != null) {
            connection.close();
        }
    }

    private boolean cancelled(Context context, SyncSettings.Pairing pairing) {
        return cancelled || !pairing.sameSession(SyncSettings.read(context));
    }

    private String displayName(ContentResolver resolver, Uri uri) {
        try (Cursor cursor = resolver.query(uri, new String[] {OpenableColumns.DISPLAY_NAME},
                 null, null, null, cancellation)) {
            return cursor != null && cursor.moveToFirst() ? cursor.getString(0) : null;
        }
    }

    private static String type(ContentResolver resolver, Uri uri, String filename) {
        String reportedType = resolver.getType(uri);
        String type = reportedType == null ? "" : reportedType.toLowerCase(Locale.ROOT);
        if (!extension(type).isEmpty() || filename == null) {
            return type;
        }
        int separator = filename.lastIndexOf('.');
        if (separator < 0) {
            return type;
        }
        String suffix = filename.substring(separator + 1).toLowerCase(Locale.ROOT);
        return switch (suffix) {
            case "mp4" -> "video/mp4";
            case "mov" -> "video/quicktime";
            case "m4v" -> "video/x-m4v";
            default -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(suffix);
        };
    }

    private static String extension(String type) {
        return switch (type == null ? "" : type) {
            case "video/mp4" -> ".mp4";
            case "video/quicktime" -> ".mov";
            case "video/x-m4v" -> ".m4v";
            default -> ScreenshotCatalog.extension(type);
        };
    }

    private static int responseError(int response) {
        return response == 401 || response == 403 ? R.string.status_bad_code : R.string.status_rejected;
    }
}
