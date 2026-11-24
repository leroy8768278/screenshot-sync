package local.snapsync.android;

import android.util.JsonReader;
import android.util.JsonToken;

import java.io.IOException;
import java.io.StringReader;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

record PairingCode(List<String> hosts, String token) {
    private static final Pattern ADDRESS = Pattern.compile("http://([0-9.]+):" + SyncSettings.PORT + "/?");

    static PairingCode parse(String text) throws IOException {
        if (text == null || text.length() > 4096) {
            throw invalid();
        }
        try (JsonReader json = new JsonReader(new StringReader(text))) {
            String type = "";
            String version = "";
            String token = "";
            List<String> hosts = new ArrayList<>();
            LinkedHashSet<String> fields = new LinkedHashSet<>();
            json.beginObject();
            while (json.hasNext()) {
                String name = json.nextName();
                if (!fields.add(name)) {
                    throw invalid();
                }
                switch (name) {
                    case "type" -> type = string(json);
                    case "version" -> {
                        if (json.peek() != JsonToken.NUMBER) {
                            throw invalid();
                        }
                        version = json.nextString();
                    }
                    case "token" -> token = string(json);
                    case "addresses" -> hosts = hosts(json);
                    default -> json.skipValue();
                }
            }
            json.endObject();
            if (json.peek() != JsonToken.END_DOCUMENT || !"snaprelay-pair".equals(type) || !"1".equals(version)
                || hosts.isEmpty() || !token.matches("[a-fA-F0-9]{24}")) {
                throw invalid();
            }
            return new PairingCode(hosts, SyncSettings.normalizedCode(token));
        } catch (IllegalStateException malformed) {
            throw invalid();
        }
    }

    private static List<String> hosts(JsonReader json) throws IOException {
        LinkedHashSet<String> hosts = new LinkedHashSet<>();
        int count = 0;
        json.beginArray();
        while (json.hasNext()) {
            Matcher address = ADDRESS.matcher(string(json));
            if (++count > 16 || !address.matches()) {
                throw invalid();
            }
            String host = address.group(1);
            if (!host.equals(SyncSettings.localHost(host))) {
                throw invalid();
            }
            hosts.add(host);
        }
        json.endArray();
        return new ArrayList<>(hosts);
    }

    private static String string(JsonReader json) throws IOException {
        if (json.peek() != JsonToken.STRING) {
            throw invalid();
        }
        return json.nextString();
    }

    private static IOException invalid() {
        return new IOException("Invalid pairing QR code");
    }
}
