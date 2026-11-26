package local.snapsync.android;

record MacProfile(String name, Family family) {
    static final MacProfile UNKNOWN = new MacProfile("", Family.GENERIC);

    enum Family {
        MINI("mac-mini", "Mac mini", R.drawable.receiver_mac_mini),
        STUDIO("mac-studio", "Mac Studio", R.drawable.receiver_mac_studio),
        IMAC("imac", "iMac", R.drawable.receiver_imac),
        PRO("mac-pro", "Mac Pro", R.drawable.receiver_mac_pro),
        BOOK_AIR("macbook-air", "MacBook Air", R.drawable.receiver_macbook_air),
        BOOK_PRO("macbook-pro", "MacBook Pro", R.drawable.receiver_macbook_pro),
        BOOK("macbook", "MacBook", R.drawable.receiver_macbook),
        BOOK_NEO("macbook-neo", "MacBook Neo", R.drawable.receiver_macbook_neo),
        GENERIC("mac", "Mac", R.drawable.receiver_mac);

        final String key;
        final String label;
        final int drawable;

        Family(String key, String label, int drawable) {
            this.key = key;
            this.label = label;
            this.drawable = drawable;
        }
    }

    static MacProfile from(String rawName, String familyKey) {
        String name = rawName == null ? "" : rawName.trim();
        if (name.length() > 256 || name.codePoints().anyMatch(ReceiverConnection::isNonDisplayable)) {
            name = "";
        }
        for (Family family : Family.values()) {
            if (family.key.equals(familyKey)) {
                return new MacProfile(name, family);
            }
        }
        return new MacProfile(name, Family.GENERIC);
    }

    String displayName() {
        return name.isEmpty() ? family.label : name;
    }
}
