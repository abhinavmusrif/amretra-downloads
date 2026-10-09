package com.amretra.devnet;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;

import java.util.UUID;

final class MessageStore extends SQLiteOpenHelper {
    private static final String DB = "devnet.db";
    private static final int VERSION = 1;

    MessageStore(Context context) {
        super(context, DB, null, VERSION);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE messages (" +
                "id TEXT PRIMARY KEY," +
                "created_at INTEGER NOT NULL," +
                "expires_at INTEGER NOT NULL," +
                "payload TEXT NOT NULL," +
                "status TEXT NOT NULL," +
                "path TEXT NOT NULL," +
                "attempts INTEGER NOT NULL DEFAULT 0)");
        db.execSQL("CREATE INDEX idx_messages_status_created ON messages(status, created_at)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        throw new IllegalStateException("No Devnet DB migration exists for " + oldVersion + " -> " + newVersion);
    }

    String enqueue(String payload, long ttlMillis) {
        long now = System.currentTimeMillis();
        String id = UUID.randomUUID().toString();
        ContentValues values = new ContentValues();
        values.put("id", id);
        values.put("created_at", now);
        values.put("expires_at", now + ttlMillis);
        values.put("payload", payload);
        values.put("status", "QUEUED");
        values.put("path", "NONE");
        getWritableDatabase().insertOrThrow("messages", null, values);
        return id;
    }

    int pendingCount() {
        try (Cursor c = getReadableDatabase().rawQuery(
                "SELECT COUNT(*) FROM messages WHERE status='QUEUED' AND expires_at > ?",
                new String[]{String.valueOf(System.currentTimeMillis())})) {
            return c.moveToFirst() ? c.getInt(0) : 0;
        }
    }

    String recentJson(int limit) {
        StringBuilder out = new StringBuilder("[");
        try (Cursor c = getReadableDatabase().rawQuery(
                "SELECT id, created_at, expires_at, payload, status, path, attempts " +
                        "FROM messages ORDER BY created_at DESC LIMIT ?",
                new String[]{String.valueOf(Math.max(1, Math.min(limit, 100))) })) {
            boolean first = true;
            while (c.moveToNext()) {
                if (!first) out.append(',');
                first = false;
                out.append('{')
                        .append("\"id\":\"").append(json(c.getString(0))).append("\",")
                        .append("\"createdAt\":").append(c.getLong(1)).append(',')
                        .append("\"expiresAt\":").append(c.getLong(2)).append(',')
                        .append("\"payload\":\"").append(json(c.getString(3))).append("\",")
                        .append("\"status\":\"").append(json(c.getString(4))).append("\",")
                        .append("\"path\":\"").append(json(c.getString(5))).append("\",")
                        .append("\"attempts\":").append(c.getInt(6))
                        .append('}');
            }
        }
        return out.append(']').toString();
    }

    static String json(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r");
    }
}
