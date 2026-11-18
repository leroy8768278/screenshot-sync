package local.snapsync.android;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.database.Cursor;
import android.net.Uri;
import android.provider.MediaStore;

import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.Locale;

final class ScreenshotCatalog {
    static final Uri IMAGES = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL);

    private static final String ID = MediaStore.Images.Media._ID;
    private static final String NAME = MediaStore.Images.Media.DISPLAY_NAME;
    private static final String PATH = MediaStore.Images.Media.RELATIVE_PATH;
    private static final String TYPE = MediaStore.Images.Media.MIME_TYPE;
    private static final String SIZE = MediaStore.Images.Media.SIZE;
    private static final String DATE = MediaStore.Images.Media.DATE_ADDED;
    private static final String DATE_TAKEN = MediaStore.Images.Media.DATE_TAKEN;
    private static final String VOLUME = MediaStore.Images.Media.VOLUME_NAME;
    private static final String[] PROJECTION = { ID, NAME, PATH, TYPE, SIZE, DATE, DATE_TAKEN, VOLUME };

    private static final DateTimeFormatter TIMESTAMP = DateTimeFormatter
        .ofPattern("uuuuMMdd-HHmmss", Locale.ROOT).withZone(ZoneId.systemDefault());

    record Screenshot(Uri uri, String id, String filename, String type, long size) {}

    static Cursor query(ContentResolver resolver, SyncSettings.Pairing pairing) {
        long sinceSeconds = pairing.history() ? 0 : pairing.since() / 1000;
        String filter = MediaStore.Images.Media.IS_PENDING + " = 0 AND "
            + "(" + DATE + " >= ? OR (? = '0' AND " + DATE + " IS NULL))";
        return resolver.query(IMAGES, PROJECTION, filter,
            new String[] { Long.toString(sinceSeconds), Long.toString(sinceSeconds) },
            DATE + " ASC, " + ID + " ASC");
    }

    static Screenshot read(Cursor cursor, SyncSettings.Pairing pairing) {
        long row = cursor.getLong(0);
        String name = cursor.getString(1);
        String path = cursor.getString(2);
        String type = cursor.getString(3);
        long size = cursor.getLong(4);
        long addedSeconds = cursor.getLong(5);
        long takenMillis = cursor.getLong(6);
        String volume = cursor.getString(7);
        if (!looksLikeScreenshot(path, name)) {
            return null;
        }
        if (!pairing.history() && (takenMillis > 0
            ? takenMillis < pairing.since()
            : addedSeconds <= pairing.since() / 1000)) {
            return null;
        }

        Uri collection = volume == null ? IMAGES : MediaStore.Images.Media.getContentUri(volume);
        Uri uri = ContentUris.withAppendedId(collection, row);
        String id = "android-" + SyncSettings.digest(pairing.installation() + ":" + uri + ":" + addedSeconds);
        String extension = extension(type);
        if (extension.isEmpty()) {
            return new Screenshot(uri, id, "", "", size);
        }
        return new Screenshot(uri, id, filename(name, row, addedSeconds, extension), type, size);
    }

    private static String extension(String type) {
        return switch (type == null ? "" : type) {
            case "image/png" -> ".png";
            case "image/jpeg" -> ".jpg";
            case "image/webp" -> ".webp";
            case "image/heic" -> ".heic";
            case "image/heif" -> ".heif";
            case "image/gif" -> ".gif";
            default -> "";
        };
    }

    private static boolean looksLikeScreenshot(String path, String name) {
        if (path != null) {
            for (String segment : path.toLowerCase(Locale.ROOT).split("/")) {
                if (segment.matches("screenshots?|screen[ _-]?(captures?|shots?)|截[图圖]|屏幕截[图圖]|屏幕快照")) {
                    return true;
                }
            }
        }
        if (name == null) {
            return false;
        }
        String lower = name.toLowerCase(Locale.ROOT);
        return lower.startsWith("screenshot_") || lower.startsWith("screenshot-")
            || lower.startsWith("screenshot ") || lower.startsWith("screen_shot_");
    }

    private static String filename(String name, long row, long addedSeconds, String extension) {
        String stem = name == null ? "" : name.replaceFirst("\\.[^.]+$", "");
        stem = stem.replaceAll("[^A-Za-z0-9._-]+", "-").replaceAll("^[._-]+|[._-]+$", "");
        if (stem.isEmpty()) {
            String timestamp = TIMESTAMP.format(Instant.ofEpochSecond(addedSeconds));
            stem = "Screenshot-" + timestamp + "-" + row;
        }
        return stem.substring(0, Math.min(stem.length(), 96)) + extension;
    }

    private ScreenshotCatalog() {}
}
