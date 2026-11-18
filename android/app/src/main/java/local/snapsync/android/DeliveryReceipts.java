package local.snapsync.android;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;

final class DeliveryReceipts extends SQLiteOpenHelper {
    DeliveryReceipts(Context context) {
        super(context, "sync_receipts.db", null, 1);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE receipts (receiver TEXT NOT NULL, screenshot TEXT NOT NULL, "
            + "PRIMARY KEY (receiver, screenshot)) WITHOUT ROWID");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        throw new IllegalStateException("Unexpected receipt database version");
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
        ContentValues values = new ContentValues();
        values.put("receiver", receiver);
        values.put("screenshot", screenshot);
        getWritableDatabase().insertWithOnConflict("receipts", null, values, SQLiteDatabase.CONFLICT_IGNORE);
    }
}
