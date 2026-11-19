package local.snapsync.android;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.URL;
import java.util.function.BooleanSupplier;

final class ReceiverConnection implements AutoCloseable {
    static final long MAX_BYTES = 64L * 1024L * 1024L;
    private static final int CONNECT_TIMEOUT_MS = 4_000;
    private static final int READ_TIMEOUT_MS = 12_000;

    private final Network network;
    private final String host;
    private final String code;
    private HttpURLConnection activeConnection;
    private boolean closed;

    ReceiverConnection(Context context, String host, String code) throws IOException {
        this.host = SyncSettings.localHost(host);
        this.code = SyncSettings.normalizedCode(code);
        if (this.host.isEmpty() || this.code.isEmpty()) {
            throw new IOException("Invalid pairing configuration");
        }
        this.network = findLocalNetwork(context);
    }

    int test() throws IOException {
        HttpURLConnection connection = open("/v1/health");
        try {
            connection.setRequestMethod("GET");
            return connection.getResponseCode();
        } finally {
            release(connection);
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
            connection.setRequestProperty("X-Device-ID", deviceId);
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
