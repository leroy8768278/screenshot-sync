package local.snapsync.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

final class ChatTransport implements AutoCloseable {
    static final long MAX_FILE = 128L * 1024 * 1024;
    static final int MAX_TEXT = 64 * 1024;
    record Message(UUID id, long sequence, long time, boolean mine, boolean file,
                   String text, String name, long bytes) {}
    record Page(List<Message> messages, boolean more, String mac) {}

    private final ReceiverConnection receiver;
    private final String device;
    private final String key;

    ChatTransport(Context app, SyncSettings.Pairing target) throws IOException {
        key = keyFor(app, target);
        device = target.deviceId();
        receiver = new ReceiverConnection(app, target.host(), target.code());
    }

    private static synchronized String keyFor(Context app, SyncSettings.Pairing target) throws IOException {
        SharedPreferences settings = SyncSettings.preferences(app);
        String name = "chat.key." + target.receiverId() + "." + target.deviceId();
        String key = settings.getString(name, null);
        if (key == null) {
            byte[] random = new byte[32];
            new SecureRandom().nextBytes(random);
            key = SyncSettings.bytesToHex(random);
            if (!settings.edit().putString(name, key).commit()) {
                throw new IOException("无法保存对话凭据");
            }
        }
        return key;
    }

    Page page(long after) throws IOException, JSONException {
        HttpURLConnection http = receiver.openChat("messages?after=" + after, device, key);
        try {
            JSONObject page = json(http, 5 * 1024 * 1024);
            List<Message> messages = new ArrayList<>();
            JSONArray rows = page.getJSONArray("messages");
            for (int i = 0; i < rows.length(); i++) {
                JSONObject row = rows.getJSONObject(i);
                long sequence = row.getLong("sequence");
                boolean file = row.getString("kind").equals("file");
                long bytes = row.getLong("bytes");
                if (sequence <= after || bytes < 0 || bytes > (file ? MAX_FILE : MAX_TEXT)) {
                    throw new IOException("对话记录格式无效");
                }
                UUID id = UUID.fromString(row.getString("id"));
                messages.add(new Message(id, sequence, (long) (row.getDouble("createdAt") * 1000),
                    "phone".equals(row.getString("sender")), file, file ? "" : row.getString("text"),
                    file ? row.getString("filename") : "", bytes));
                after = sequence;
            }
            boolean more = page.getBoolean("hasMore");
            if (more && messages.isEmpty()) { throw new IOException("对话记录分页无效"); }
            return new Page(messages, more, page.optString("macName", "Mac"));
        } finally { http.disconnect(); }
    }

    void sendText(UUID id, String text) throws IOException, JSONException {
        byte[] body = text.getBytes(StandardCharsets.UTF_8);
        if (body.length > MAX_TEXT) { throw new IOException("单条文字最大 64 KiB"); }
        send(id, null, new ByteArrayInputStream(body), body.length);
    }

    void send(UUID id, String filename, InputStream input, long size) throws IOException, JSONException {
        boolean file = filename != null;
        if (size < 0 || size > (file ? MAX_FILE : MAX_TEXT)) { throw new IOException("附件最大 128 MiB"); }
        HttpURLConnection http = receiver.openChat(file ? "file" : "text", device, key);
        try {
            http.setRequestMethod("POST");
            http.setDoOutput(true);
            http.setFixedLengthStreamingMode(size);
            http.setReadTimeout(120_000);
            http.setRequestProperty("Content-Type", file ? "application/octet-stream" : "text/plain; charset=utf-8");
            http.setRequestProperty("X-Message-ID", id.toString());
            if (file) {
                http.setRequestProperty("X-File-Name", Base64.encodeToString(
                    filename.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP));
            }
            try (OutputStream out = http.getOutputStream()) {
                if (copy(input, out, size) != size) { throw new IOException("文件大小已改变，请重新选择"); }
            }
            if (!id.toString().equalsIgnoreCase(json(http, 512 * 1024).getString("id"))) {
                throw new IOException("未收到发送确认，请重试");
            }
        } finally { http.disconnect(); }
    }

    void download(Message attachment, File output) throws IOException {
        HttpURLConnection http = receiver.openChat("files/" + attachment.id(), device, key);
        try {
            http.setReadTimeout(120_000);
            check(http);
            if (http.getContentLengthLong() != attachment.bytes()) { throw new IOException("附件长度不符"); }
            try (InputStream raw = http.getInputStream(); OutputStream out = new FileOutputStream(output)) {
                if (copy(raw, out, attachment.bytes()) != attachment.bytes()) {
                    throw new IOException("附件未传输完整");
                }
            }
        } finally { http.disconnect(); }
    }

    private static void check(HttpURLConnection http) throws IOException {
        int status = http.getResponseCode();
        if (status == 404) { throw new IOException("请检查 Mac 端版本和附件是否可用"); }
        if (status == 401 || status == 403) { throw new IOException("对话认证失败，请检查配对"); }
        if (status != 200 && status != 201) { throw new IOException("Mac 返回 HTTP " + status); }
    }

    private static JSONObject json(HttpURLConnection http, int limit) throws IOException, JSONException {
        check(http);
        try (InputStream raw = http.getInputStream()) {
            ByteArrayOutputStream data = new ByteArrayOutputStream();
            copy(raw, data, limit);
            return new JSONObject(data.toString("UTF-8"));
        }
    }

    static long copy(InputStream raw, OutputStream out, long limit) throws IOException {
        if (raw == null || out == null) { throw new IOException("无法打开文件"); }
        byte[] block = new byte[64 * 1024];
        long total = 0;
        int count;
        while ((count = raw.read(block)) != -1) {
            total += count;
            if (total > limit || Thread.currentThread().isInterrupted()) {
                throw new IOException("传输已中断或文件超过大小限制");
            }
            out.write(block, 0, count);
        }
        return total;
    }

    @Override public void close() { receiver.close(); }
}
