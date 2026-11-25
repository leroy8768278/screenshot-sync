package local.snapsync.android;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;

import org.json.JSONArray;
import org.json.JSONException;

import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

final class ChatDownloads {
    private static final int GRANTS = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
    record Saved(Uri uri, String registration) {}
    private record Metadata(String name, long bytes, long modified, long flags) {}
    private final Context app;
    private final ContentResolver resolver;
    private final SharedPreferences index;

    ChatDownloads(Context context) {
        app = context.getApplicationContext();
        resolver = app.getContentResolver();
        index = app.getSharedPreferences("conversation_downloads", Context.MODE_PRIVATE);
    }

    static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    // Only the exact local document returned by CREATE_DOCUMENT can become a deletion candidate.
    boolean remember(String room, Uri uri, int flags, long bytes, byte[] digest) {
        String authority = uri.getAuthority();
        // A provider may return an already registered URI for another save. Retire its old ownership.
        String uriKey = uri.toString();
        if (index.contains(uriKey)) { index.edit().remove(uriKey).apply(); }
        if (!("com.android.providers.downloads.documents".equals(authority)
                || "com.android.externalstorage.documents".equals(authority))
                || (flags & GRANTS) != GRANTS || !DocumentsContract.isDocumentUri(app, uri)) {
            return false;
        }
        try {
            Metadata info = metadata(uri);
            if (info.bytes >= 0 && info.bytes != bytes) { return false; }
            String record = new JSONArray().put(room).put(SyncSettings.bytesToHex(digest)).put(bytes)
                .put(info.name).put(info.modified).toString();
            resolver.takePersistableUriPermission(uri, GRANTS);
            if (index.edit().putString(uriKey, record).commit()) { return true; }
            resolver.releasePersistableUriPermission(uri, GRANTS);
            return false;
        } catch (IOException | RuntimeException e) {
            return false;
        }
    }

    List<Saved> saved(String room) {
        List<Saved> result = new ArrayList<>();
        for (Map.Entry<String, ?> item : index.getAll().entrySet()) {
            if (!(item.getValue() instanceof String record)) { continue; }
            try {
                if (new JSONArray(record).getString(0).equals(room)) {
                    result.add(new Saved(Uri.parse(item.getKey()), record));
                }
            } catch (JSONException ignored) { /* An unreadable entry cannot authorize deletion. */ }
        }
        return result;
    }

    private Metadata metadata(Uri uri) throws IOException {
        String[] columns = {Document.COLUMN_DISPLAY_NAME, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS};
        try (Cursor row = resolver.query(uri, columns, null, null, null)) {
            if (row == null || !row.moveToFirst() || row.isNull(0)) { throw new IOException("无法读取保存的文件"); }
            return new Metadata(row.getString(0), row.isNull(1) ? -1 : row.getLong(1),
                row.isNull(2) ? -1 : row.getLong(2), row.getLong(3));
        }
    }

    boolean delete(Saved saved) {
        Uri uri = saved.uri;
        try {
            if (!saved.registration.equals(index.getString(uri.toString(), null))) { return false; }
            JSONArray record = new JSONArray(saved.registration);
            long bytes = record.getLong(2);
            Metadata before = metadata(uri);
            if (!record.getString(3).equals(before.name) || record.getLong(4) != before.modified
                    || (before.flags & Document.FLAG_SUPPORTS_DELETE) == 0
                    || (before.bytes >= 0 && before.bytes != bytes)) {
                return false;
            }
            MessageDigest digest = sha256();
            try (InputStream stream = resolver.openInputStream(uri)) {
                if (stream == null) { return false; }
                byte[] block = new byte[64 * 1024];
                long total = 0;
                int count;
                while ((count = stream.read(block)) != -1) {
                    total += count;
                    if (total > bytes || Thread.currentThread().isInterrupted()) { return false; }
                    digest.update(block, 0, count);
                }
                if (total != bytes || !record.getString(1).equals(SyncSettings.bytesToHex(digest.digest()))) {
                    return false;
                }
            }
            if (!before.equals(metadata(uri)) || !DocumentsContract.deleteDocument(resolver, uri)) { return false; }
        } catch (JSONException | IOException | RuntimeException ex) {
            return false;
        }
        index.edit().remove(uri.toString()).apply();
        try { resolver.releasePersistableUriPermission(uri, GRANTS); }
        catch (SecurityException ignored) { /* Some providers drop the grant when the document is deleted. */ }
        return true;
    }
}
