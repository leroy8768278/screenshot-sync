package local.snapsync.android;

import android.content.Context;
import android.content.SharedPreferences;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.UUID;

final class SyncSettings {
    static final String STATUS = "status";
    static final int PORT = 43871;
    private static final String HOST = "host";
    private static final String CODE = "code";
    private static final String AUTO = "auto";
    private static final String PAUSED = "paused";
    private static final String CONNECTED_AT = "connected_at";
    private static final String GENERATION = "generation";
    private static final String INSTALLATION = "installation";
    private static final Object SETTINGS_LOCK = new Object();

    record Pairing(String host, String code, boolean paused, long connectedAt,
                   String generation, String installation) {
        boolean isConfigured() {
            return !host.isEmpty() && !code.isEmpty();
        }

        boolean isVerified() {
            return isConfigured() && connectedAt > 0;
        }

        String receiverId() {
            return digest(code);
        }

        String deviceId() {
            return installation.replace("-", "").toLowerCase(Locale.ROOT);
        }

        boolean canSync() {
            return isVerified() && !paused;
        }

        boolean sameSession(Pairing other) {
            return isVerified() && connectedAt == other.connectedAt && code.equals(other.code);
        }
    }

    static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences("sync_settings", Context.MODE_PRIVATE);
    }

    static Pairing read(Context context) {
        synchronized (SETTINGS_LOCK) {
            SharedPreferences prefs = preferences(context);
            return new Pairing(
                prefs.getString(HOST, ""),
                prefs.getString(CODE, ""),
                prefs.getBoolean(PAUSED, false) || !prefs.getBoolean(AUTO, true),
                prefs.getLong(CONNECTED_AT, 0),
                prefs.getString(GENERATION, ""),
                prefs.getString(INSTALLATION, "")
            );
        }
    }

    static boolean saveVerified(Context context, String host, String code, long verifiedAt) {
        synchronized (SETTINGS_LOCK) {
            Pairing old = read(context);
            boolean sameReceiver = old.isConfigured() && old.code.equals(code);
            boolean paused = sameReceiver && old.paused;
            long cutoff = sameReceiver && old.isVerified() ? old.connectedAt : verifiedAt;
            String installation = old.installation.isEmpty()
                ? UUID.randomUUID().toString() : old.installation;
            boolean endpointChanged = !old.host.equals(host) || !sameReceiver || !old.isVerified();
            return preferences(context).edit()
                .putString(HOST, host)
                .putString(CODE, code)
                .remove(AUTO)
                .remove("launch_started_at")
                .putBoolean(PAUSED, paused)
                .putLong(CONNECTED_AT, cutoff)
                .putString(GENERATION, endpointChanged ? UUID.randomUUID().toString() : old.generation)
                .putString(INSTALLATION, installation)
                .putString(STATUS, context.getString(paused ? R.string.status_paused : R.string.status_connected))
                .commit();
        }
    }

    static boolean setPaused(Context context, boolean paused) {
        synchronized (SETTINGS_LOCK) {
            Pairing pairing = read(context);
            if (!pairing.isVerified()) {
                return false;
            }
            return preferences(context).edit()
                .remove(AUTO)
                .putBoolean(PAUSED, paused)
                .putString(GENERATION, UUID.randomUUID().toString())
                .putString(STATUS, context.getString(paused ? R.string.status_paused : R.string.status_connected))
                .commit();
        }
    }

    static boolean disconnect(Context context) {
        synchronized (SETTINGS_LOCK) {
            return preferences(context).edit()
                .remove(HOST)
                .remove(CODE)
                .remove(CONNECTED_AT)
                .remove(PAUSED)
                .remove(AUTO)
                .remove("launch_started_at")
                .remove(STATUS)
                .putString(GENERATION, UUID.randomUUID().toString())
                .commit();
        }
    }

    static boolean isCurrent(Context context, Pairing pairing) {
        return pairing.generation.equals(read(context).generation);
    }

    static void status(Context context, Pairing pairing, int message, Object... arguments) {
        synchronized (SETTINGS_LOCK) {
            if (isCurrent(context, pairing)) {
                preferences(context).edit().putString(STATUS, context.getString(message, arguments)).apply();
            }
        }
    }

    static String localHost(String text) {
        String address = text.trim();
        String portSuffix = ":" + PORT;
        if (address.endsWith(portSuffix)) {
            address = address.substring(0, address.length() - portSuffix.length());
        }
        String[] parts = address.split("\\.", -1);
        if (parts.length != 4) {
            return "";
        }

        int[] octets = new int[4];
        for (int i = 0; i < parts.length; i++) {
            if (!parts[i].matches("[0-9]{1,3}")) {
                return "";
            }
            octets[i] = Integer.parseInt(parts[i]);
            if (octets[i] > 255) {
                return "";
            }
        }

        int first = octets[0];
        int second = octets[1];
        boolean privateAddress = first == 10 || (first == 172 && second >= 16 && second <= 31)
            || (first == 192 && second == 168) || (first == 169 && second == 254);
        if (!privateAddress) {
            return "";
        }
        return String.format(Locale.ROOT, "%d.%d.%d.%d", first, second, octets[2], octets[3]);
    }

    static String normalizedCode(String text) {
        String code = text.trim().toLowerCase(Locale.ROOT);
        return code.matches("[a-f0-9]{24}") ? code : "";
    }

    static String digest(String text) {
        try {
            byte[] bytes = MessageDigest.getInstance("SHA-256")
                .digest(text.getBytes(StandardCharsets.UTF_8));
            return bytesToHex(bytes);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    static String bytesToHex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            result.append(Character.forDigit((value >>> 4) & 15, 16));
            result.append(Character.forDigit(value & 15, 16));
        }
        return result.toString();
    }

    private SyncSettings() {}
}
