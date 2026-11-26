package local.snapsync.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.graphics.Rect;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.HorizontalScrollView;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONException;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.text.DateFormat;
import java.util.*;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class DeviceChat {
    private static final int PICK = 11, SAVE = 12;
    private final MainActivity app;
    final LinearLayout entry, page;
    private final LinearLayout history, attachments;
    private final HorizontalScrollView attachmentStrip;
    private final Button choose, send, clearHistory;
    private final TextView entryTitle, snippet, title, status;
    private final EditText input;
    private final GestureDetector composerTaps;
    private final ScrollView scroll;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Runnable tick = this::poll;
    private final List<ChatTransport.Message> messages = new ArrayList<>();
    private final List<Attachment> files = new ArrayList<>();
    private final Set<UUID> received = new HashSet<>();
    private final File cache;
    private final ChatDownloads downloads;
    private SyncSettings.Pairing target;
    private boolean active, busy, polling;
    private volatile boolean destroyed;
    private volatile long epoch;
    private long lastRead, clearedThrough;
    private String mac = "Mac", networkError = "", notice = "", lastAttemptText;
    private UUID attemptId;
    private String chooserRoom = "", saveId = "";
    private File export;
    private volatile ChatTransport connection;

    private record Attachment(UUID id, File file, String name) {}
    private interface Work { void run(long generation, SyncSettings.Pairing pairing) throws Exception; }

    DeviceChat(MainActivity app) {
        this.app = app;
        cache = new File(app.getCacheDir(), "conversation");
        downloads = new ChatDownloads(app);
        entry = app.column();
        entry.setPadding(app.dp(16), app.dp(10), app.dp(16), app.dp(12));
        entry.setBackground(app.shape(app.panel, app.border, 18));
        entry.setFocusable(true);
        entry.setOnClickListener(v -> openPage());
        TypedValue feedback = new TypedValue();
        app.getTheme().resolveAttribute(android.R.attr.selectableItemBackground, feedback, true);
        entry.setForeground(app.getDrawable(feedback.resourceId));
        entry.setClipToOutline(true);
        entry.setAccessibilityDelegate(new View.AccessibilityDelegate() {
            @Override public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
                super.onInitializeAccessibilityNodeInfo(host, info);
                info.setClassName(Button.class.getName());
            }
        });
        LinearLayout entryRow = new LinearLayout(app);
        entryRow.setGravity(Gravity.CENTER_VERTICAL);
        entryRow.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        entryTitle = app.label(0, 17, app.ink, true);
        entryTitle.setSingleLine(true);
        entryTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);
        entryRow.addView(entryTitle, new LinearLayout.LayoutParams(0, -2, 1));
        TextView chevron = app.label(0, 22, app.muted, false);
        chevron.setText("›");
        entryRow.addView(chevron);
        app.add(entry, entryRow, 0);
        snippet = app.label(0, 13, app.muted, false);
        snippet.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        snippet.setSingleLine(true);
        snippet.setEllipsize(android.text.TextUtils.TruncateAt.END);
        app.add(entry, snippet, 4);

        page = app.column();
        page.setVisibility(View.GONE);
        page.setFocusableInTouchMode(true);
        page.setBackgroundColor(app.paper);
        page.setPadding(app.dp(12), app.dp(6), app.dp(12), app.dp(8));
        LinearLayout header = new LinearLayout(app);
        header.setGravity(Gravity.CENTER_VERTICAL);
        Button back = app.button(R.string.chat_back, false);
        back.setMinWidth(0);
        back.setOnClickListener(v -> returnHome());
        header.addView(back);
        title = app.label(0, 18, app.ink, true);
        title.setSingleLine(true);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        title.setAccessibilityHeading(true);
        title.setPaddingRelative(app.dp(10), 0, app.dp(8), 0);
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
        clearHistory = app.button(R.string.chat_more, false);
        clearHistory.setOnClickListener(v -> {
            android.widget.PopupMenu menu = new android.widget.PopupMenu(app, clearHistory);
            menu.getMenu().add(R.string.chat_clear).setOnMenuItemClickListener(item -> {
                confirmClear();
                return true;
            });
            menu.show();
        });
        header.addView(clearHistory);
        app.add(page, header, 0);

        scroll = new ScrollView(app);
        scroll.setFillViewport(true);
        history = app.column();
        history.setPadding(app.dp(4), app.dp(8), app.dp(4), app.dp(8));
        scroll.addView(history);
        page.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout composer = app.column();
        composer.setBackground(app.glassSurface(22));
        composer.setPadding(app.dp(8), app.dp(4), app.dp(8), app.dp(6));
        app.add(page, composer, 4);
        input = new EditText(app);
        composerTaps = new GestureDetector(app, new GestureDetector.SimpleOnGestureListener() {
            private boolean startedOutside;

            @Override public boolean onDown(MotionEvent event) {
                startedOutside = input.hasFocus() && !touchesInput(event);
                return true;
            }

            @Override public boolean onSingleTapUp(MotionEvent event) {
                if (startedOutside && !touchesInput(event)) {
                    input.post(() -> {
                        View focus = app.getCurrentFocus();
                        if (focus != input && focus != null && focus.onCheckIsTextEditor()) { return; }
                        app.getSystemService(InputMethodManager.class).hideSoftInputFromWindow(input.getWindowToken(), 0);
                        input.clearFocus();
                    });
                }
                return false;
            }
        });
        input.setHint("输入或粘贴文字");
        input.setHintTextColor(app.muted);
        input.setBackgroundColor(android.graphics.Color.TRANSPARENT);
        input.setPaddingRelative(app.dp(8), app.dp(10), app.dp(6), app.dp(10));
        input.setMaxLines(3);
        input.setTextColor(app.ink);
        input.setTextSize(15);
        input.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        input.setGravity(Gravity.CENTER_VERTICAL | Gravity.START);

        attachmentStrip = new HorizontalScrollView(app);
        attachments = new LinearLayout(app);
        attachmentStrip.addView(attachments);
        app.add(composer, attachmentStrip, 0);
        choose = app.button(R.string.chat_pick, false);
        choose.setOnClickListener(v -> pick());
        send = app.button(R.string.chat_send, true);
        send.setOnClickListener(v -> send());
        LinearLayout actions = new LinearLayout(app);
        actions.setGravity(Gravity.CENTER_VERTICAL);
        actions.addView(choose);
        actions.addView(input, new LinearLayout.LayoutParams(0,-2,1));
        actions.addView(send);
        app.add(composer, actions, 2);
        status = app.label(0, 12, app.muted, false);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        app.add(composer, status, 2);
        input.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            public void onTextChanged(CharSequence s, int start, int before, int count) { updateActions(); }
            public void afterTextChanged(Editable e) {}
        });
        render();
    }

    boolean isOpen() { return page.getVisibility() == View.VISIBLE; }

    private void openPage() {
        if (target == null || isOpen()) { return; }
        app.showChatPage(true);
        markRead();
        renderHistory(true);
        render();
        poll();
    }

    void returnHome() {
        if (!isOpen()) { return; }
        persistDraft();
        app.showChatPage(false);
    }

    private boolean touchesInput(MotionEvent event) {
        Rect visible = new Rect();
        if (!input.getLocalVisibleRect(visible)) { return false; }
        int[] origin = new int[2];
        input.getLocationOnScreen(origin);
        visible.offset(origin[0], origin[1]);
        return visible.contains((int) event.getRawX(), (int) event.getRawY());
    }

    void observeTouch(MotionEvent event) { if (isOpen()) { composerTaps.onTouchEvent(event); } }

    void bind(SyncSettings.Pairing next) {
        if (next != null && !next.isVerified()) { next = null; }
        if (next == null && target == null) { return; }
        if (next != null && target != null && next.sameSession(target) && next.host().equals(target.host())) { return; }
        if (isOpen()) { returnHome(); }
        else { persistDraft(); }
        epoch++;
        main.removeCallbacks(tick);
        ChatTransport old = connection;
        if (old != null) { old.close(); }
        target = next;
        polling = false; busy = false;
        messages.clear(); files.clear(); received.clear();
        cleanupExport();
        chooserRoom = ""; mac = next == null ? "Mac" : next.mac().displayName(); notice = networkError = "";
        restoreDraft();
        clearedThrough = next == null ? 0 : SyncSettings.preferences(app).getLong("chat.cleared." + draftKey(), 0);
        lastRead = next == null ? 0 : SyncSettings.preferences(app).getLong("chat.read." + next.receiverId(), 0);
        render(); renderFiles();
        poll();
    }

    void foreground(boolean value) {
        active = value;
        main.removeCallbacks(tick);
        if (value) {
            bind(SyncSettings.read(app));
            markRead(); poll();
        } else {
            persistDraft();
        }
    }

    void close() {
        destroyed = true; epoch++;
        main.removeCallbacks(tick);
        ChatTransport wire = connection;
        if (wire != null) { wire.close(); }
        io.shutdownNow();
        if (app.isFinishing()) { cleanupExport(); }
    }

    // Publish the socket before checking the generation. Either this worker or bind() then
    // closes it if re-pairing races with work that was waiting in the serial queue.
    private ChatTransport openCurrent(long owner, SyncSettings.Pairing pair) throws IOException {
        ChatTransport wire = new ChatTransport(app, pair);
        connection = wire;
        if (!current(owner) || !pair.sameSession(SyncSettings.read(app))) {
            wire.close();
            throw new IOException("配对已切换");
        }
        return wire;
    }

    private boolean current(long owner) { return !destroyed && epoch == owner; }
    private void post(long owner, Runnable callback) {
        main.post(() -> { if (current(owner)) { callback.run(); } });
    }
    private String room() { return target == null ? "" : target.receiverId() + ":" + target.connectedAt(); }
    private long latest() { return messages.isEmpty() ? clearedThrough : messages.get(messages.size() - 1).sequence(); }
    private void markRead() {
        if (target != null && active && isOpen() && latest() > lastRead) {
            lastRead = latest();
            SyncSettings.preferences(app).edit().putLong("chat.read." + target.receiverId(), lastRead).apply();
        }
    }

    private void poll() {
        main.removeCallbacks(tick);
        if (!active || target == null || destroyed || polling) { return; }
        polling = true;
        long owner = epoch, after = latest();
        SyncSettings.Pairing pair = target;
        io.execute(() -> {
            boolean more = false;
            try (ChatTransport wire = openCurrent(owner, pair)) {
                ChatTransport.Page page = wire.page(after);
                more = page.more();
                post(owner, () -> {
                    networkError = "";
                    mac = page.mac().isEmpty() || "Mac".equals(page.mac()) ? pair.mac().displayName() : page.mac();
                    for (ChatTransport.Message item : page.messages()) {
                        if (item.sequence() > clearedThrough) { messages.add(item); }
                    }
                    markRead();
                    if (isOpen() && !page.messages().isEmpty()) {
                        renderHistory(page.messages().stream().anyMatch(ChatTransport.Message::mine));
                    }
                    render();
                });
            } catch (Exception ex) {
                post(owner, () -> { networkError = message(ex); render(); });
            } finally {
                connection = null;
                int delay = more ? 0 : 3500;
                post(owner, () -> { polling = false; if (active) { main.postDelayed(tick, delay); } });
            }
        });
    }

    private static String message(Exception error) {
        String text = error.getLocalizedMessage();
        return text == null || !text.matches("(?s).*\\p{IsHan}.*") ? "暂时无法传输，请检查连接后重试" : text;
    }

    private void render() {
        int unread = 0;
        for (ChatTransport.Message m : messages) { if (!m.mine() && m.sequence() > lastRead) { unread++; } }
        String chatTitle = app.getString(R.string.chat_open, mac);
        String entryText = app.getString(R.string.chat_entry);
        entryTitle.setText(unread > 0 ? app.getString(R.string.chat_with_unread, entryText, unread) : entryText);
        title.setText(mac);
        page.setAccessibilityPaneTitle(chatTitle);
        ChatTransport.Message last = messages.isEmpty() ? null : messages.get(messages.size() - 1);
        snippet.setText(last == null ? "文字和文件" : last.file() ? "文件 · " + last.name() : last.text());
        CharSequence preview = snippet.getText();
        entry.setContentDescription(entryTitle.getText() + "。" + preview.subSequence(0, Math.min(120, preview.length())));
        status.setText(!networkError.isEmpty() && !notice.isEmpty() ? notice + "\n" + networkError
            : networkError.isEmpty() ? notice : networkError);
        status.setVisibility(status.length() == 0 ? View.GONE : View.VISIBLE);
        updateActions();
    }

    private void updateActions() {
        input.setEnabled(!busy);
        choose.setEnabled(!busy);
        clearHistory.setEnabled(!busy && target != null);
        send.setEnabled(!busy && (input.getText().toString().trim().length() > 0 || !files.isEmpty()));
    }

    private void renderHistory(boolean showLatest) {
        boolean followLatest = showLatest || !scroll.canScrollVertically(1);
        history.removeAllViews();
        history.setGravity(messages.isEmpty() ? Gravity.CENTER : Gravity.TOP);
        if (messages.isEmpty()) {
            TextView empty = app.label(0, 13, app.muted, false); empty.setText("暂无消息"); empty.setGravity(Gravity.CENTER); app.add(history, empty, 0);
        }
        for (ChatTransport.Message m : messages) {
            LinearLayout row = app.column();
            row.setGravity(m.mine() ? Gravity.END : Gravity.START);
            row.setPaddingRelative(m.mine() ? app.dp(32) : 0, 0, m.mine() ? 0 : app.dp(32), 0);
            TextView stamp = app.label(0, 12, app.muted, false);
            stamp.setText((m.mine() ? "我" : mac) + " · " + DateFormat.getTimeInstance(DateFormat.SHORT).format(new Date(m.time())));
            row.addView(stamp, -2, -2);
            TextView bubble = app.label(0, 15, app.ink, false);
            bubble.setText(m.file() ? m.name() + " · " + size(m.bytes()) : m.text());
            bubble.setTextIsSelectable(m.file());
            bubble.setPadding(app.dp(10), app.dp(7), app.dp(10), app.dp(7));
            bubble.setBackground(app.shape(m.mine() ? app.tint : app.panel, app.border, 14));
            row.addView(bubble, -2, -2);
            if (!m.file()) {
                bubble.setOnLongClickListener(view -> {
                    copyMessage(m.text());
                    return true;
                });
                bubble.setFocusable(true);
                bubble.setAccessibilityDelegate(new View.AccessibilityDelegate() {
                    @Override public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
                        super.onInitializeAccessibilityNodeInfo(host, info);
                        info.addAction(new AccessibilityNodeInfo.AccessibilityAction(
                            AccessibilityNodeInfo.ACTION_LONG_CLICK, app.getString(R.string.chat_copy)));
                    }
                });
            } else {
                if (!m.mine()) { action(row, received.contains(m.id()) ? "再次保存" : "接收", () -> download(m, false)); }
                if (m.name().toLowerCase(Locale.ROOT).endsWith(".txt")) { action(row, "查看文本", () -> download(m, true)); }
            }
            app.add(history, row, 7);
        }
        if (followLatest) { scroll.post(() -> scroll.scrollTo(0, history.getHeight())); }
    }

    private void copyMessage(String text) {
        app.getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("即图", text));
        notice = "已复制";
        render();
    }

    private void action(LinearLayout parent, String label, Runnable click) {
        Button b = new Button(app, null, android.R.attr.borderlessButtonStyle);
        b.setText(label); b.setAllCaps(false); b.setMinHeight(app.dp(36));
        b.setOnClickListener(v -> click.run()); parent.addView(b, -2, -2);
    }
    private static String size(long bytes) {
        if (bytes < 1024) { return bytes + " B"; }
        return bytes < 1048576 ? String.format(Locale.ROOT, "%.1f KB", bytes / 1024.0)
            : String.format(Locale.ROOT, "%.1f MB", bytes / 1048576.0);
    }

    private void confirmClear() {
        if (target == null || busy) { return; }
        long owner = epoch, cutoff = latest();
        int count = messages.size();
        List<ChatDownloads.Saved> saved = downloads.saved(draftKey());
        if (count == 0 && saved.isEmpty()) { notice = "当前对话没有可清除的记录或已登记下载"; render(); return; }

        LinearLayout options = app.column();
        options.setPadding(app.dp(22), app.dp(10), app.dp(22), 0);
        TextView description = app.label(0, 14, app.ink, false);
        description.setText("将从这部手机清除与 " + mac + " 的 " + count + " 条记录。Mac 上的记录会保留。");
        app.add(options, description, 0);
        CheckBox deleteFiles = new CheckBox(app);
        deleteFiles.setText("同时删除已保存的本机文件（" + saved.size() + " 个）");
        deleteFiles.setEnabled(!saved.isEmpty());
        app.add(options, deleteFiles, 10);
        TextView help = app.label(0, 13, app.muted, false);
        help.setText("旧版保存的文件、另存的副本可在系统文件管理器中清理。");
        app.add(options, help, 2);
        AlertDialog dialog = new AlertDialog.Builder(app).setTitle("清除本机对话记录？").setView(options)
            .setNegativeButton("取消", null)
            .setPositiveButton("清除", (d, which) -> {
                if (current(owner) && !busy) {
                    clear(cutoff, deleteFiles.isChecked() ? saved : Collections.emptyList());
                }
            }).create();
        dialog.show();
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setTextColor(0xffb42318);
    }

    private void clear(long cutoff, List<ChatDownloads.Saved> saved) {
        String key = "chat.cleared." + draftKey();
        work("正在清除…", (owner, pair) -> {
            if (!SyncSettings.preferences(app).edit().putLong(key, cutoff).commit()) {
                throw new IOException("清除位置保存失败，请重试");
            }
            post(owner, () -> {
                clearedThrough = cutoff;
                messages.removeIf(m -> m.sequence() <= cutoff);
                renderHistory(false);
            });
            int deleted = 0;
            for (ChatDownloads.Saved item : saved) {
                if (!current(owner)) { return; }
                if (downloads.delete(item)) { deleted++; }
            }
            String result = saved.isEmpty() ? "已清除本机对话记录" : "已清除记录，删除 " + deleted + " 个文件"
                + (deleted == saved.size() ? "" : "，" + (saved.size() - deleted) + " 个未删除，可在文件管理器中核对");
            post(owner, () -> { notice = result; render(); });
        });
    }

    private void renderFiles() {
        attachmentStrip.setVisibility(files.isEmpty() ? View.GONE : View.VISIBLE);
        attachments.removeAllViews();
        for (Attachment file : files) {
            Button remove = new Button(app, null, android.R.attr.borderlessButtonStyle);
            remove.setText(file.name() + " · " + size(file.file().length()) + "    ×");
            remove.setContentDescription("移除附件 " + file.name());
            remove.setAllCaps(false); remove.setEnabled(!busy);
            remove.setOnClickListener(v -> {
                if (!busy) { files.remove(file); file.file().delete(); persistDraft(); renderFiles(); render(); }
            });
            attachments.addView(remove);
        }
        updateActions();
    }

    private void work(String label, Work work) {
        if (busy || target == null || destroyed) { return; }
        final long owner = epoch;
        SyncSettings.Pairing pair = target;
        busy = true; notice = label; render(); renderFiles();
        io.execute(() -> {
            try { if (current(owner)) { work.run(owner, pair); } }
            catch (Exception ex) { post(owner, () -> { notice = message(ex); }); }
            finally {
                post(owner, () -> { busy = false; renderFiles(); render(); poll(); });
            }
        });
    }

    private File temporary(String prefix) throws IOException {
        if (!cache.isDirectory() && !cache.mkdirs() && !cache.isDirectory()) { throw new IOException("无法准备附件目录"); }
        return File.createTempFile(prefix, ".tmp", cache);
    }

    private void pick() {
        chooserRoom = room();
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        try { app.startActivityForResult(intent, PICK); }
        catch (android.content.ActivityNotFoundException e) { notice = "系统文件选择器不可用"; render(); }
    }

    boolean result(int request, int result, Intent data) {
        if (request != PICK && request != SAVE) { return false; }
        if (result != Activity.RESULT_OK || data == null || !room().equals(chooserRoom) || target == null) {
            if (request == SAVE) { cleanupExport(); }
            return true;
        }
        if (request == SAVE) {
            saveExport(data.getData(), data.getFlags());
            return true;
        }
        Set<Uri> uris = new LinkedHashSet<>();
        if (data.getData() != null) { uris.add(data.getData()); }
        ClipData clip = data.getClipData();
        if (clip != null) { for (int i = 0; i < clip.getItemCount(); i++) { uris.add(clip.getItemAt(i).getUri()); } }
        work("正在准备附件…", (owner, pair) -> {
            for (Uri uri : uris) {
                if (!current(owner)) { return; }
                if (uri == null || !"content".equals(uri.getScheme())) { continue; }
                String name = "附件";
                try (Cursor cursor = app.getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) { name = cursor.getString(0); }
                }
                UUID id = UUID.randomUUID();
                File file = temporary("out");
                try (InputStream in = app.getContentResolver().openInputStream(uri); OutputStream out = new FileOutputStream(file)) {
                    ChatTransport.copy(in, out, ChatTransport.MAX_FILE);
                } catch (Exception ex) { file.delete(); throw ex; }
                Attachment item = new Attachment(id, file, name);
                main.post(() -> { if (current(owner)) { files.add(item); persistDraft(); renderFiles(); } else { file.delete(); } });
            }
            post(owner, () -> { notice = ""; });
        });
        return true;
    }

    private void send() {
        final String text = input.getText().toString();
        final List<Attachment> batch = new ArrayList<>(files);
        if (!text.equals(lastAttemptText) || attemptId == null) {
            lastAttemptText = text; attemptId = UUID.randomUUID();
        }
        UUID id = attemptId;
        persistDraft();
        work("正在发送…", (owner, pair) -> {
            try (ChatTransport wire = openCurrent(owner, pair)) {
                if (!text.trim().isEmpty()) {
                    wire.sendText(id, text);
                    post(owner, () -> { input.setText(""); attemptId = null; persistDraft(); });
                }
                for (Attachment item : batch) {
                    if (!pair.sameSession(SyncSettings.read(app))) { throw new IOException("配对已切换"); }
                    try (InputStream in = new FileInputStream(item.file())) {
                        wire.send(item.id(), item.name(), in, item.file().length());
                    }
                    post(owner, () -> { files.remove(item); item.file().delete(); persistDraft(); renderFiles(); });
                }
                post(owner, () -> { notice = "已发送"; });
            } finally { connection = null; }
        });
    }

    private void download(ChatTransport.Message m, boolean preview) {
        work("正在接收…", (owner, pair) -> {
            File file = temporary("incoming");
            try (ChatTransport wire = openCurrent(owner, pair)) {
                wire.download(m, file);
            } catch (Exception ex) { file.delete(); throw ex; }
            finally { connection = null; }
            if (preview) {
                int length = (int) Math.min(file.length(), 65536);
                byte[] content = new byte[length];
                try (DataInputStream in = new DataInputStream(new FileInputStream(file))) { in.readFully(content); }
                finally { file.delete(); }
                String text = new String(content, StandardCharsets.UTF_8) + (m.bytes() > length ? "\n（预览前 64 KB）" : "");
                post(owner, () -> {
                    notice = "";
                    if (!isOpen()) { return; }
                    new AlertDialog.Builder(app).setTitle(m.name()).setMessage(text).setPositiveButton("关闭", null).show();
                });
            } else {
                main.post(() -> {
                    if (!current(owner) || !isOpen()) { file.delete(); return; }
                    cleanupExport();
                    export = file; saveId = m.id().toString(); chooserRoom = room();
                    Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                        .setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, m.name());
                    try { app.startActivityForResult(intent, SAVE); notice = ""; }
                    catch (android.content.ActivityNotFoundException ex) { cleanupExport(); notice = "系统文件选择器不可用"; }
                });
            }
        });
    }
    private void saveExport(Uri uri, int grantFlags) {
        if (export == null || uri == null || !"content".equals(uri.getScheme())) { cleanupExport(); return; }
        File file = export;
        String saved = saveId;
        export = null; saveId = "";
        work("正在保存…", (owner, pair) -> {
            var digest = ChatDownloads.sha256();
            long size;
            try (InputStream in = new java.security.DigestInputStream(new FileInputStream(file), digest);
                 OutputStream out = app.getContentResolver().openOutputStream(uri, "wt")) {
                size = ChatTransport.copy(in, out, ChatTransport.MAX_FILE);
            } finally { file.delete(); }
            boolean tracked = downloads.remember(pair.receiverId() + "." + pair.deviceId(), uri, grantFlags, size, digest.digest());
            post(owner, () -> {
                received.add(UUID.fromString(saved));
                notice = tracked ? "已保存到所选位置" : "已保存。此位置的副本请在文件管理器中清理。";
                renderHistory(false);
            });
        });
    }
    private void cleanupExport() { if (export != null) { export.delete(); } export = null; saveId = ""; }

    private SharedPreferences drafts() {
        return app.getSharedPreferences("conversation_drafts", MainActivity.MODE_PRIVATE);
    }

    private String draftKey() { return target.receiverId() + "." + target.deviceId(); }

    private void persistDraft() {
        if (target == null) { return; }
        String key = draftKey();
        String text = input.getText().toString();
        SharedPreferences.Editor changes = drafts().edit();
        if (text.isEmpty()) { changes.remove(key + ".text"); }
        else { changes.putString(key + ".text", text); }
        if (attemptId == null || !text.equals(lastAttemptText)) { changes.remove(key + ".attempt"); }
        else { changes.putString(key + ".attempt", attemptId.toString()); }
        if (files.isEmpty()) {
            changes.remove(key + ".files");
        } else {
            JSONArray items = new JSONArray();
            for (Attachment item : files) {
                items.put(new JSONArray().put(item.id().toString()).put(item.file().getName()).put(item.name()));
            }
            changes.putString(key + ".files", items.toString());
        }
        changes.apply();
    }

    private void restoreDraft() {
        input.setText(""); attemptId = null; lastAttemptText = null;
        if (target == null) { return; }
        SharedPreferences saved = drafts();
        String key = draftKey();
        lastAttemptText = saved.getString(key + ".text", "");
        input.setText(lastAttemptText);
        String id = saved.getString(key + ".attempt", null);
        try {
            if (id != null) { attemptId = UUID.fromString(id); }
            JSONArray items = new JSONArray(saved.getString(key + ".files", "[]"));
            for (int i = 0; i < items.length(); i++) {
                JSONArray item = items.getJSONArray(i);
                String name = item.getString(1);
                if (!name.matches("out[0-9-]+\\.tmp")) { continue; }
                File file = new File(cache, name);
                if (file.isFile()) {
                    files.add(new Attachment(UUID.fromString(item.getString(0)), file, item.getString(2)));
                } else {
                    notice = "部分附件缓存已清理，请重新选择";
                }
            }
        } catch (IllegalArgumentException | JSONException e) {
            notice = "无法完整恢复对话草稿，请检查附件";
        }
    }

    void save(Bundle state) {
        persistDraft();
        state.putString("chatRoom", room());
        state.putString("chatChooser", chooserRoom);
        state.putString("chatExport", export == null ? "" : export.getName());
        state.putString("chatSaveID", saveId);
        state.putBoolean("chatOpen", isOpen());
    }

    void restore(Bundle state, SyncSettings.Pairing pair) {
        bind(pair);
        if (state == null || target == null || !room().equals(state.getString("chatRoom"))) { return; }
        chooserRoom = state.getString("chatChooser", "");
        String temp = state.getString("chatExport", "");
        if (temp.matches("incoming[0-9-]+\\.tmp")) {
            export = new File(cache, temp); saveId = state.getString("chatSaveID", "");
        }
        if (state.getBoolean("chatOpen")) { openPage(); }
    }
}
