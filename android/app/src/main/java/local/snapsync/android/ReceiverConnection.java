package local.snapsync.android;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Base64;
import android.util.JsonReader;
import android.util.JsonToken;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.StringReader;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;

final class ReceiverConnection implements AutoCloseable {
    static final long MAX_BYTES = 64L * 1024L * 1024L;
    static final long MAX_VIDEO_BYTES = 512L * 1024L * 1024L;
    private static final int CONNECT_TIMEOUT_MS = 4_000;
    private static final int READ_TIMEOUT_MS = 12_000;

    private final Context context;
    private final Network network;
    private final String host;
    private final String code;
    private HttpURLConnection activeConnection;
    private boolean closed;

    ReceiverConnection(Context context, String host, String code) throws IOException {
        this.context = context.getApplicationContext();
        this.host = SyncSettings.localHost(host);
        this.code = SyncSettings.normalizedCode(code);
        if (this.host.isEmpty() || this.code.isEmpty()) {
            throw new IOException("Invalid pairing configuration");
        }
        this.network = findLocalNetwork(context);
    }

    void reportDevice(String deviceId) throws IOException {
        HttpURLConnection connection = open("/v1/devices");
        try {
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(0);
            connection.setConnectTimeout(2_000);
            connection.setReadTimeout(2_000);
            setDeviceHeaders(connection, deviceId);
            connection.getOutputStream().close();
            connection.getResponseCode();
        } finally {
            release(connection);
        }
    }

    private void setDeviceHeaders(HttpURLConnection connection, String deviceId) {
        Map<String, String> fields = new HashMap<>();
        try {
            addField(fields, "name", Settings.Global.getString(context.getContentResolver(), Settings.Global.DEVICE_NAME));
        } catch (RuntimeException unavailable) {
            // Some devices restrict access to the user-assigned name.
        }
        addField(fields, "model", Build.MODEL);
        addField(fields, "osVersion", Build.VERSION.RELEASE);
        byte[] json = new JSONObject(fields).toString().getBytes(StandardCharsets.UTF_8);
        connection.setRequestProperty("X-Device-Info", Base64.encodeToString(json, Base64.NO_WRAP));
        connection.setRequestProperty("X-Device-Platform", "android");
        connection.setRequestProperty("X-Device-ID", deviceId);
    }

    private static void addField(Map<String, String> fields, String key, String value) {
        if (value == null) {
            return;
        }
        String text = value.trim();
        int limit = key.equals("osVersion") ? 128 : 256;
        if (!text.isEmpty() && !Build.UNKNOWN.equalsIgnoreCase(text)
                && text.getBytes(StandardCharsets.UTF_8).length <= limit
                && text.codePoints().noneMatch(ReceiverConnection::isNonDisplayable)) {
            fields.put(key, text);
        }
    }

    static boolean isNonDisplayable(int codePoint) {
        return switch (Character.getType(codePoint)) {
            case Character.CONTROL, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true;
            case Character.FORMAT -> codePoint != 0x200C && codePoint != 0x200D;
            default -> false;
        };
    }

    record Health(int status, MacProfile mac) {}

    Health test() throws IOException {
        HttpURLConnection connection = open("/v1/health");
        try {
            connection.setRequestMethod("GET");
            connection.setConnectTimeout(2_000);
            connection.setReadTimeout(2_000);
            int status = connection.getResponseCode();
            if (status == 200) {
                try (InputStream body = connection.getInputStream()) {
                    return new Health(status, checkHealth(body));
                }
            }
            return new Health(status, MacProfile.UNKNOWN);
        } finally {
            release(connection);
        }
    }

    private static MacProfile checkHealth(InputStream body) throws IOException {
        ByteArrayOutputStream response = new ByteArrayOutputStream();
        byte[] buffer = new byte[512];
        int count;
        long deadline = SystemClock.elapsedRealtime() + 2_000;
        while ((count = body.read(buffer)) != -1) {
            if (response.size() + count > 4096 || SystemClock.elapsedRealtime() > deadline) {
                throw new IOException("Invalid receiver response");
            }
            response.write(buffer, 0, count);
        }
        String payload = new String(response.toByteArray(), StandardCharsets.UTF_8);
        try (JsonReader json = new JsonReader(new StringReader(payload))) {
            boolean healthy = false;
            String macName = "";
            String macFamily = "";
            json.beginObject();
            while (json.hasNext()) {
                String key = json.nextName();
                if ("status".equals(key)) {
                    if (healthy || json.peek() != JsonToken.STRING || !"ok".equals(json.nextString())) {
                        throw new IOException("Invalid receiver status");
                    }
                    healthy = true;
                } else if ("macName".equals(key) && json.peek() == JsonToken.STRING) {
                    macName = json.nextString();
                } else if ("macFamily".equals(key) && json.peek() == JsonToken.STRING) {
                    macFamily = json.nextString();
                } else {
                    json.skipValue();
                }
            }
            json.endObject();
            if (!healthy || json.peek() != JsonToken.END_DOCUMENT) {
                throw new IOException("Invalid receiver response");
            }
            return MacProfile.from(macName, macFamily);
        } catch (IllegalStateException malformed) {
            throw new IOException("Invalid receiver response", malformed);
        }
    }

    int upload(InputStream input, long length, String id, String deviceId, String filename,
               String type, BooleanSupplier cancelled) throws IOException {
        checkCancelled(cancelled);

        HttpURLConnection connection = open("/v1/screenshots");
        try {
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(length);
            connection.setRequestProperty("Content-Type", type);
            connection.setRequestProperty("X-Screenshot-ID", id);
            setDeviceHeaders(connection, deviceId);
            connection.setRequestProperty("X-Filename", filename);
            try (OutputStream output = connection.getOutputStream()) {
                byte[] buffer = new byte[64 * 1024];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    checkCancelled(cancelled);
                    output.write(buffer, 0, count);
                }
            }
            return connection.getResponseCode();
        } finally {
            release(connection);
        }
    }

    HttpURLConnection openChat(String route, String device, String key) throws IOException {
        HttpURLConnection http = open("/v1/chat/" + route);
        setDeviceHeaders(http, device);
        http.setRequestProperty("X-Chat-Key", key);
        return http;
    }

    private HttpURLConnection open(String path) throws IOException {
        URL url = new URL("http", host, SyncSettings.PORT, path);
        HttpURLConnection connection = (HttpURLConnection) network.openConnection(url, Proxy.NO_PROXY);
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
        connection.setReadTimeout(READ_TIMEOUT_MS);
        connection.setRequestProperty("Authorization", "Bearer " + code);
        synchronized (this) {
            if (closed) {
                throw new IOException("Sync interrupted");
            }
            activeConnection = connection;
        }
        return connection;
    }

    @Override
    public void close() {
        HttpURLConnection connection;
        synchronized (this) {
            closed = true;
            connection = activeConnection;
            activeConnection = null;
        }
        if (connection != null) {
            connection.disconnect();
        }
    }

    private void release(HttpURLConnection connection) {
        synchronized (this) {
            if (activeConnection != connection) {
                return;
            }
            activeConnection = null;
        }
        connection.disconnect();
    }

    private static void checkCancelled(BooleanSupplier cancelled) throws IOException {
        if (cancelled.getAsBoolean()) {
            throw new IOException("Sync interrupted");
        }
    }

    private static Network findLocalNetwork(Context context) throws IOException {
        ConnectivityManager manager = context.getSystemService(ConnectivityManager.class);
        Network active = manager.getActiveNetwork();
        if (isLocalNetwork(manager, active)) {
            return active;
        }
        for (Network candidate : manager.getAllNetworks()) {
            if (isLocalNetwork(manager, candidate)) {
                return candidate;
            }
        }
        throw new IOException("Wi-Fi or Ethernet is not available");
    }

    private static boolean isLocalNetwork(ConnectivityManager manager, Network network) {
        if (network == null) {
            return false;
        }
        NetworkCapabilities caps = manager.getNetworkCapabilities(network);
        return caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET));
    }
}
