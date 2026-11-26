package local.snapsync.android;

import android.content.ContentValues;
import android.content.Context;
import android.graphics.Bitmap;
import android.net.Uri;
import android.util.Size;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;

final class DeliveryReceipts extends SQLiteOpenHelper {
    static final String UPDATED = "recent_deliveries_updated";
    private final Context context;

    record Delivery(String id, String name, String type, long bytes, long time, boolean manual, byte[] preview) {}

    DeliveryReceipts(Context context) {
        super(context, "sync_receipts.db", null, 3);
        this.context = context.getApplicationContext();
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE receipts (receiver TEXT NOT NULL, screenshot TEXT NOT NULL, "
            + "PRIMARY KEY (receiver, screenshot)) WITHOUT ROWID");
        createHistory(db);
        createLastDelivery(db);
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        if (oldVersion < 2) { createHistory(db); }
        if (oldVersion < 3) {
            createLastDelivery(db);
            db.execSQL("INSERT INTO last_delivery SELECT receiver,MAX(delivered) FROM deliveries GROUP BY receiver");
        }
    }

    private static void createHistory(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE deliveries (receiver TEXT NOT NULL, item TEXT NOT NULL, name TEXT NOT NULL,"
            + " type TEXT NOT NULL, bytes INTEGER NOT NULL, delivered INTEGER NOT NULL, manual INTEGER NOT NULL,"
            + " preview BLOB, UNIQUE(receiver, item))");
        db.execSQL("CREATE INDEX delivery_order ON deliveries(receiver, delivered DESC)");
    }

    private static void createLastDelivery(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE last_delivery (receiver TEXT PRIMARY KEY, delivered INTEGER NOT NULL) WITHOUT ROWID");
    }

    long lastDelivery(String receiver) {
        try (Cursor row = getReadableDatabase().rawQuery(
            "SELECT delivered FROM last_delivery WHERE receiver=?", new String[] { receiver })) {
            return row.moveToFirst() ? row.getLong(0) : 0;
        }
    }

    List<Delivery> recent(String receiver) {
        List<Delivery> result = new ArrayList<>();
        try (Cursor rows = getReadableDatabase().rawQuery("SELECT item,name,type,bytes,delivered,manual,preview"
                + " FROM deliveries WHERE receiver=? ORDER BY delivered DESC,rowid DESC LIMIT 12", new String[] {receiver})) {
            while (rows.moveToNext()) {
                result.add(new Delivery(rows.getString(0), rows.getString(1), rows.getString(2), rows.getLong(3), rows.getLong(4),
                    rows.getInt(5) != 0, rows.getBlob(6)));
            }
        }
        return result;
    }

    void clearRecent(String receiver, List<String> items) {
        SQLiteDatabase db = getWritableDatabase();
        db.beginTransaction();
        try {
            for (String item : items) {
                db.delete("deliveries", "receiver=? AND item=?", new String[] { receiver, item });
            }
            db.setTransactionSuccessful();
        } finally {
            db.endTransaction();
        }
    }

    boolean contains(String receiver, String screenshot) {
        try (Cursor cursor = getReadableDatabase().query(
            "receipts", new String[] { "screenshot" }, "receiver = ? AND screenshot = ?",
            new String[] { receiver, screenshot }, null, null, null, "1"
        )) {
            return cursor.moveToFirst();
        }
    }

    void remember(String receiver, String screenshot) {
        insert(getWritableDatabase(), receiver, screenshot);
    }

    void delivered(String receiver, String item, String contentReceipt, Uri uri,
                   String name, String type, long bytes, boolean manual) {
        ContentValues entry = new ContentValues();
        entry.put("receiver", receiver);
        entry.put("item", item);
        entry.put("name", name);
        entry.put("type", type);
        entry.put("bytes", bytes);
        entry.put("delivered", System.currentTimeMillis());
        entry.put("manual", manual);
        try {
            Bitmap preview = context.getContentResolver().loadThumbnail(uri, new Size(96, 96), null);
            if (preview != null) {
                ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                preview.compress(Bitmap.CompressFormat.JPEG, 75, buffer);
                preview.recycle();
                entry.put("preview", buffer.toByteArray());
            }
        } catch (IOException | RuntimeException unavailable) {
            // Document providers without thumbnails still get a receipt and a media-type fallback.
        }
        SQLiteDatabase database = getWritableDatabase();
        database.beginTransaction();
        try {
            insert(database, receiver, item);
            if (!manual) { insert(database, receiver, contentReceipt); }
            database.insertOrThrow("deliveries", null, entry);
            database.execSQL("INSERT OR REPLACE INTO last_delivery(receiver,delivered)"
                + " VALUES(?,MAX(?,COALESCE((SELECT delivered FROM last_delivery WHERE receiver=?),0)))",
                new Object[] {receiver, entry.getAsLong("delivered"), receiver});
            database.execSQL("DELETE FROM deliveries WHERE receiver=? AND rowid NOT IN"
                + " (SELECT rowid FROM deliveries WHERE receiver=? ORDER BY delivered DESC,rowid DESC LIMIT 12)",
                new Object[] {receiver, receiver});
            database.setTransactionSuccessful();
        } finally {
            database.endTransaction();
        }
        SyncSettings.preferences(context).edit().putLong(UPDATED, System.nanoTime()).apply();
    }

    private void insert(SQLiteDatabase database, String receiver, String screenshot) {
        ContentValues values = new ContentValues();
        values.put("receiver", receiver);
        values.put("screenshot", screenshot);
        database.insertWithOnConflict("receipts", null, values, SQLiteDatabase.CONFLICT_IGNORE);
    }
}
