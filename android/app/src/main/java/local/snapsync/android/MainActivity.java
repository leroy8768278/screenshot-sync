package local.snapsync.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.database.ContentObserver;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.provider.Settings;
import android.text.InputType;
import android.text.method.PasswordTransformationMethod;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.InputMethodManager;
import android.util.Size;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.IOException;
import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int REQUEST_PHOTOS = 1;
    private static final int PICK_IMAGES = 2;
    private static final int BACKGROUND = 0xfff3f6fb;
    private static final int INK = 0xff172641;
    private static final int MUTED = 0xff52617a;
    private static final int ACCENT = 0xff2457c6;
    private static final int BORDER = 0xffd8e0ed;
    private static final int FIELD = 0xfff8faff;
    private static final int ERROR = 0xffa3262e;
    private static final int HOST_ID = View.generateViewId();
    private static final int CODE_ID = View.generateViewId();

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService connectionExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService manualExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService previewExecutor = Executors.newSingleThreadExecutor();
    private final Runnable scanOnChange = () -> triggerForegroundSync();
    private final ContentObserver photos = new ContentObserver(handler) {
        @Override
        public void onChange(boolean selfChange) {
            handler.removeCallbacks(scanOnChange);
            handler.postDelayed(scanOnChange, 600);
        }
    };
    private final SharedPreferences.OnSharedPreferenceChangeListener statusListener = (prefs, key) -> {
        if (SyncSettings.STATUS.equals(key)) {
            showSavedStatus();
        }
    };

    private EditText hostInput;
    private EditText codeInput;
    private LinearLayout pairingPanel;
    private LinearLayout syncPanel;
    private TextView connectedReceiver;
    private TextView syncMode;
    private TextView testStatus;
    private TextView syncStatus;
    private TextView permissionStatus;
    private Button connectButton;
    private Button connectionSettings;
    private Button disconnectButton;
    private Button requestPermissionButton;
    private Button openSettingsButton;
    private Button chooseImagesButton;
    private Button retryButton;
    private Button cancelSendButton;
    private Button syncControlButton;
    private TextView manualStatus;
    private boolean observerRegistered;
    private boolean verifying;
    private boolean editingConnection;
    private boolean migrationAttempted;
    private String pickerSession = "";
    private String selectedSession = "";
    private ArrayList<Uri> selectedImages = new ArrayList<>();
    private ManualSend manual;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        SyncScheduler.cancelLegacyScan(this);
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
        }
        setContentView(buildContent());

        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (pairing.isConfigured()) {
            showReceiverAddress(pairing.host());
            codeInput.setText(pairing.code());
        }
        if (savedInstanceState != null) {
            pickerSession = savedInstanceState.getString("picker_session", "");
            selectedSession = savedInstanceState.getString("selected_session", "");
            ArrayList<Uri> restored = Build.VERSION.SDK_INT >= 33
                ? savedInstanceState.getParcelableArrayList("selected_images", Uri.class)
                : savedInstanceState.getParcelableArrayList("selected_images");
            if (restored != null && pairing.isVerified() && selectedSession.equals(sessionKey(pairing))) {
                selectedImages = restored;
            }
        }
        SyncScheduler.configure(this, pairing);
        showSavedStatus();
    }

    @Override
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putString("picker_session", pickerSession);
        state.putString("selected_session", selectedSession);
        state.putParcelableArrayList("selected_images", selectedImages);
    }

    @Override
    protected void onStart() {
        super.onStart();
        SyncSettings.preferences(this).registerOnSharedPreferenceChangeListener(statusListener);
        showSavedStatus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshPermissions();
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        SyncScheduler.configure(this, pairing);
        if (pairing.isConfigured() && !pairing.isVerified() && !migrationAttempted) {
            migrationAttempted = true;
            verifyConnection(new Input(pairing.host(), pairing.code()));
        }
        triggerForegroundSync();
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(scanOnChange);
        updateObserver(false);
        super.onPause();
    }

    @Override
    protected void onStop() {
        SyncSettings.preferences(this).unregisterOnSharedPreferenceChangeListener(statusListener);
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        if (manual != null) {
            manual.close();
        }
        connectionExecutor.shutdownNow();
        manualExecutor.shutdownNow();
        previewExecutor.shutdownNow();
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_PHOTOS) {
            refreshPermissions();
            SyncScheduler.configure(this, SyncSettings.read(this));
            triggerForegroundSync();
        }
    }

    private View buildContent() {
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(BACKGROUND);
        scroll.setFillViewport(true);
        scroll.setClipToPadding(false);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets edges = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                view.setPadding(edges.left, edges.top, edges.right, edges.bottom);
            } else {
                view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        getWindow().getDecorView().setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
        FrameLayout centered = new FrameLayout(this);
        scroll.addView(centered, new ScrollView.LayoutParams(
            ScrollView.LayoutParams.MATCH_PARENT, ScrollView.LayoutParams.WRAP_CONTENT));

        LinearLayout page = column();
        page.setFocusableInTouchMode(true);
        page.setPadding(dp(20), dp(26), dp(20), dp(26));
        int contentWidth = getResources().getDisplayMetrics().widthPixels;
        FrameLayout.LayoutParams pageParams = new FrameLayout.LayoutParams(
            Math.min(contentWidth, dp(580)), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        centered.addView(page, pageParams);

        TextView title = label(R.string.app_name, 30, INK, true);
        title.setAccessibilityHeading(true);
        add(page, title, 0);
        add(page, label(R.string.subtitle, 14, MUTED, false), 6);
        pairingPanel = pairingCard();
        syncPanel = statusCard();
        add(page, syncPanel, 20);
        add(page, pairingPanel, 12);
        return scroll;
    }

    private LinearLayout pairingCard() {
        LinearLayout card = card(R.string.connect_title);
        add(card, label(R.string.connect_help, 13, MUTED, false), 8);
        TextView addressLabel = label(R.string.host, 13, INK, true);
        addressLabel.setLabelFor(HOST_ID);
        add(card, addressLabel, 16);
        hostInput = field(HOST_ID, R.string.host_hint, InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        add(card, hostInput, 6);

        TextView codeLabel = label(R.string.code, 13, INK, true);
        codeLabel.setLabelFor(CODE_ID);
        add(card, codeLabel, 12);
        codeInput = field(CODE_ID, R.string.code_hint,
            InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        codeInput.setSaveEnabled(false);
        Button visibility = button(R.string.show_code, false);
        visibility.setOnClickListener(view -> {
            boolean show = codeInput.getTransformationMethod() instanceof PasswordTransformationMethod;
            codeInput.setTransformationMethod(show ? null : PasswordTransformationMethod.getInstance());
            codeInput.setSelection(codeInput.length());
            visibility.setText(show ? R.string.hide_code : R.string.show_code);
        });
        LinearLayout codeRow = row();
        codeRow.addView(codeInput, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        LinearLayout.LayoutParams visibilityParams = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        visibilityParams.setMarginStart(dp(8));
        codeRow.addView(visibility, visibilityParams);
        add(card, codeRow, 6);

        connectButton = button(R.string.connect_title, true);
        connectButton.setOnClickListener(view -> {
            Input input = readInput();
            if (input != null) {
                verifyConnection(input);
            }
        });
        add(card, connectButton, 12);
        testStatus = label(0, 13, MUTED, false);
        testStatus.setVisibility(View.GONE);
        testStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(card, testStatus, 10);
        disconnectButton = button(R.string.disconnect, false);
        disconnectButton.setOnClickListener(view -> confirmDisconnect());
        add(card, disconnectButton, 10);
        return card;
    }

    private LinearLayout statusCard() {
        LinearLayout page = column();
        LinearLayout destination = card(R.string.receiver);
        connectedReceiver = label(0, 14, INK, false);
        add(destination, connectedReceiver, 7);
        connectionSettings = button(R.string.connection_settings, false);
        connectionSettings.setOnClickListener(view -> {
            editingConnection = !editingConnection;
            refreshSyncControls();
            if (editingConnection) {
                pairingPanel.post(() -> pairingPanel.requestRectangleOnScreen(
                    new Rect(0, 0, pairingPanel.getWidth(), dp(128)), false));
            }
        });
        add(destination, connectionSettings, 10);
        add(page, destination, 0);

        LinearLayout card = card(R.string.automatic);
        syncMode = label(0, 14, INK, true);
        add(card, syncMode, 9);
        syncStatus = label(R.string.status_setup, 13, MUTED, false);
        syncStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(card, syncStatus, 5);
        permissionStatus = label(R.string.permission_missing, 13, MUTED, false);
        add(card, permissionStatus, 8);
        requestPermissionButton = button(R.string.permission, false);
        requestPermissionButton.setOnClickListener(view -> requestPermissions(PhotoAccess.permissions(), REQUEST_PHOTOS));
        openSettingsButton = button(R.string.open_settings, false);
        openSettingsButton.setOnClickListener(view -> startActivity(new Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", getPackageName(), null))));
        add(card, actionRow(requestPermissionButton, openSettingsButton), 8);

        syncControlButton = button(R.string.stop_sync, false);
        syncControlButton.setOnClickListener(view -> toggleSyncPause());
        add(card, syncControlButton, 10);
        add(page, card, 12);

        chooseImagesButton = button(R.string.pick_images, true);
        chooseImagesButton.setOnClickListener(view -> openImagePicker());
        add(page, chooseImagesButton, 12);
        manualStatus = label(0, 13, MUTED, false);
        manualStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        manualStatus.setVisibility(View.GONE);
        add(page, manualStatus, 8);
        retryButton = button(R.string.manual_retry, false);
        retryButton.setOnClickListener(view -> confirmImages());
        add(page, retryButton, 8);
        cancelSendButton = button(R.string.manual_cancel, false);
        cancelSendButton.setOnClickListener(view -> {
            if (manual != null) {
                manual.close();
                cancelSendButton.setEnabled(false);
                showManualStatus(getString(R.string.manual_cancelling));
            }
        });
        add(page, cancelSendButton, 8);
        add(page, label(R.string.background_hint, 12, MUTED, false), 14);
        return page;
    }

    private record Input(String host, String code) {}

    private Input readInput() {
        String host = SyncSettings.localHost(hostInput.getText().toString());
        if (host.isEmpty()) {
            hostInput.setError(getString(R.string.invalid_host));
            hostInput.requestFocus();
            return null;
        }
        String code = SyncSettings.normalizedCode(codeInput.getText().toString());
        if (code.isEmpty()) {
            codeInput.setError(getString(R.string.invalid_code));
            codeInput.requestFocus();
            return null;
        }
        return new Input(host, code);
    }

    private void verifyConnection(Input input) {
        if (verifying) {
            return;
        }
        verifying = true;
        refreshSyncControls();
        showTestResult(R.string.status_testing, false);
        connectionExecutor.execute(() -> {
            int response;
            try (ReceiverConnection receiver = new ReceiverConnection(getApplicationContext(), input.host(), input.code())) {
                response = receiver.test();
            } catch (IOException failure) {
                response = 0;
            }
            int result = response;
            long verifiedAt = System.currentTimeMillis();
            runOnUiThread(() -> {
                if (isDestroyed()) {
                    return;
                }
                verifying = false;
                switch (result) {
                    case 200 -> saveVerified(input, verifiedAt);
                    case 401, 403 -> showTestResult(R.string.status_bad_code, true);
                    case 0 -> showTestResult(R.string.status_network, true);
                    default -> showTestResult(R.string.status_rejected, true, result);
                }
                refreshSyncControls();
            });
        });
    }

    private void saveVerified(Input input, long verifiedAt) {
        if (!SyncSettings.saveVerified(this, input.host(), input.code(), verifiedAt)) {
            showTestResult(R.string.save_failed, true);
            return;
        }
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (!selectedSession.equals(sessionKey(pairing))) {
            clearSelection();
            manualStatus.setVisibility(View.GONE);
        }

        showReceiverAddress(input.host());
        codeInput.setText(input.code());
        getSystemService(InputMethodManager.class).hideSoftInputFromWindow(hostInput.getWindowToken(), 0);
        hostInput.clearFocus();
        codeInput.clearFocus();
        editingConnection = false;
        testStatus.setVisibility(View.GONE);
        SyncScheduler.configure(this, pairing);
        refreshPermissions();
        triggerForegroundSync();
    }

    private void confirmDisconnect() {
        new AlertDialog.Builder(this)
            .setTitle(R.string.disconnect)
            .setMessage(R.string.disconnect_explanation)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.disconnect, (dialog, which) -> {
                if (!SyncSettings.disconnect(this)) {
                    showTestResult(R.string.save_failed, true);
                    return;
                }
                clearSelection();
                editingConnection = false;
                manualStatus.setVisibility(View.GONE);
                testStatus.setVisibility(View.GONE);
                hostInput.setText("");
                codeInput.setText("");
                SyncScheduler.configure(this, SyncSettings.read(this));
                showSavedStatus();
                refreshPermissions();
            })
            .show();
    }

    private void toggleSyncPause() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        boolean pause = !pairing.paused();
        if (!SyncSettings.setPaused(this, pause)) {
            syncStatus.setText(R.string.save_failed);
            return;
        }
        handler.removeCallbacks(scanOnChange);
        SyncScheduler.configure(this, SyncSettings.read(this));
        refreshPermissions();
        if (!pause) {
            triggerForegroundSync();
        }
    }

    private void triggerForegroundSync() {
        SyncScheduler.sync(this, SyncSettings.read(this));
    }

    private void refreshPermissions() {
        PhotoAccess access = PhotoAccess.current(this);
        permissionStatus.setText(access == PhotoAccess.LIMITED
            ? R.string.permission_partial : R.string.permission_missing);
        permissionStatus.setVisibility(access == PhotoAccess.FULL ? View.GONE : View.VISIBLE);
        requestPermissionButton.setText(access == PhotoAccess.LIMITED
            ? R.string.permission_button_partial : R.string.permission);
        requestPermissionButton.setVisibility(access == PhotoAccess.FULL ? View.GONE : View.VISIBLE);
        openSettingsButton.setVisibility(access == PhotoAccess.FULL ? View.GONE : View.VISIBLE);
        refreshSyncControls();
        updateObserver(access == PhotoAccess.FULL && SyncSettings.read(this).canSync());
    }

    private void refreshSyncControls() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        boolean connected = pairing.isVerified();
        boolean configured = pairing.isConfigured();
        syncPanel.setVisibility(connected ? View.VISIBLE : View.GONE);
        pairingPanel.setVisibility(connected && !editingConnection ? View.GONE : View.VISIBLE);
        boolean sending = manual != null;
        connectButton.setEnabled(!verifying && !sending);
        disconnectButton.setVisibility(configured ? View.VISIBLE : View.GONE);
        disconnectButton.setEnabled(!verifying && !sending);
        connectionSettings.setEnabled(!sending && !verifying);
        chooseImagesButton.setEnabled(connected && !sending && !verifying);
        retryButton.setVisibility(!selectedImages.isEmpty() && !sending ? View.VISIBLE : View.GONE);
        retryButton.setEnabled(connected && !verifying);
        cancelSendButton.setVisibility(sending ? View.VISIBLE : View.GONE);
        syncControlButton.setEnabled(!verifying);
        syncControlButton.setText(pairing.paused() ? R.string.resume_sync : R.string.stop_sync);
        if (!connected) {
            return;
        }

        String timestamp = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
            .format(new Date(pairing.connectedAt()));
        connectedReceiver.setText(getString(R.string.connection_summary, pairing.host(), SyncSettings.PORT, timestamp));
        syncMode.setText(pairing.paused() ? R.string.automatic_paused
            : PhotoAccess.current(this) == PhotoAccess.FULL ? R.string.automatic_running : R.string.automatic_needs_permission);
    }

    @SuppressWarnings("deprecation")
    private void openImagePicker() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (!pairing.isVerified()) {
            return;
        }
        pickerSession = sessionKey(pairing);
        if (Build.VERSION.SDK_INT >= 33) {
            Intent photoPicker = new Intent(MediaStore.ACTION_PICK_IMAGES)
                .setType("image/*")
                .putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit());
            try {
                startActivityForResult(photoPicker, PICK_IMAGES);
                return;
            } catch (ActivityNotFoundException unavailable) {
                // Some devices provide the document picker only.
            }
        }
        Intent documents = new Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("image/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        try {
            startActivityForResult(documents, PICK_IMAGES);
        } catch (ActivityNotFoundException unavailable) {
            pickerSession = "";
            showManualStatus(getString(R.string.manual_picker_missing));
        }
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != PICK_IMAGES) {
            return;
        }
        String session = pickerSession;
        pickerSession = "";
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (result != RESULT_OK || data == null || !pairing.isVerified() || !session.equals(sessionKey(pairing))) {
            return;
        }
        LinkedHashSet<Uri> images = new LinkedHashSet<>();
        addSelectedUri(images, data.getData());
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                addSelectedUri(images, clip.getItemAt(i).getUri());
            }
        }
        if (images.isEmpty()) {
            return;
        }
        selectedSession = session;
        selectedImages = new ArrayList<>(images);
        confirmImages();
    }

    private static void addSelectedUri(LinkedHashSet<Uri> images, Uri uri) {
        if (uri != null && "content".equals(uri.getScheme())) {
            images.add(uri);
        }
    }

    private void confirmImages() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (selectedImages.isEmpty() || !pairing.isVerified() || !selectedSession.equals(sessionKey(pairing))) {
            return;
        }
        List<Uri> selection = new ArrayList<>(selectedImages);
        LinearLayout previewContent = column();
        previewContent.setPadding(dp(20), dp(8), dp(20), dp(8));
        TextView message = label(0, 14, INK, false);
        message.setText(getString(R.string.manual_confirm_receiver, pairing.host(), SyncSettings.PORT, selection.size()));
        add(previewContent, message, 0);
        HorizontalScrollView thumbnails = new HorizontalScrollView(this);
        LinearLayout images = row();
        thumbnails.addView(images);
        add(previewContent, thumbnails, 10);
        CancellationSignal cancellation = new CancellationSignal();
        for (Uri uri : selection.subList(0, Math.min(selection.size(), 6))) {
            ImageView thumbnail = new ImageView(this);
            thumbnail.setBackground(shape(FIELD, BORDER, 8));
            thumbnail.setScaleType(ImageView.ScaleType.CENTER_CROP);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(dp(62), dp(62));
            params.setMarginEnd(dp(8));
            images.addView(thumbnail, params);
            previewExecutor.execute(() -> {
                try {
                    var bitmap = getContentResolver().loadThumbnail(uri, new Size(dp(62), dp(62)), cancellation);
                    runOnUiThread(() -> thumbnail.setImageBitmap(bitmap));
                } catch (IOException | RuntimeException unavailable) {
                    // Some document providers cannot provide previews. The item remains selected.
                }
            });
        }
        AlertDialog dialog = new AlertDialog.Builder(this)
            .setTitle(R.string.manual_confirm_title)
            .setView(previewContent)
            .setNegativeButton(android.R.string.cancel, (alert, which) -> {
                clearSelection();
                refreshSyncControls();
            })
            .setPositiveButton(getString(R.string.manual_send, selection.size()),
                (alert, which) -> startSend(pairing, selection))
            .create();
        dialog.setOnCancelListener(alert -> {
            clearSelection();
            refreshSyncControls();
        });
        dialog.setOnDismissListener(alert -> cancellation.cancel());
        dialog.show();
    }

    private void startSend(SyncSettings.Pairing pairing, List<Uri> selection) {
        SyncSettings.Pairing current = SyncSettings.read(this);
        if (manual != null || !pairing.sameSession(current) || !pairing.host().equals(current.host())) {
            return;
        }
        ManualSend transfer = new ManualSend();
        manual = transfer;
        cancelSendButton.setEnabled(true);
        showManualStatus(getString(R.string.manual_sending, selection.size()));
        refreshSyncControls();
        manualExecutor.execute(() -> {
            ManualSend.Result result = transfer.send(getApplicationContext(), pairing, selection);
            runOnUiThread(() -> finishSend(transfer, result));
        });
    }

    private void finishSend(ManualSend transfer, ManualSend.Result result) {
        if (isDestroyed() || manual != transfer) {
            return;
        }
        manual = null;
        selectedImages = new ArrayList<>(result.pending());
        String summary = getString(R.string.manual_result, result.sent(), result.alreadySynced(), selectedImages.size());
        if (result.error() != 0) {
            summary += "\n" + getString(result.error(), result.response());
        }
        showManualStatus(summary);
        refreshSyncControls();
    }

    private void showManualStatus(String message) {
        manualStatus.setText(message);
        manualStatus.setVisibility(View.VISIBLE);
    }

    private void clearSelection() {
        selectedImages.clear();
        selectedSession = "";
    }

    private static String sessionKey(SyncSettings.Pairing pairing) {
        return pairing.receiverId() + ":" + pairing.connectedAt();
    }

    private void updateObserver(boolean observe) {
        if (!observe && observerRegistered) {
            getContentResolver().unregisterContentObserver(photos);
            observerRegistered = false;
        } else if (observe && !observerRegistered) {
            try {
                getContentResolver().registerContentObserver(ScreenshotCatalog.IMAGES, true, photos);
                observerRegistered = true;
            } catch (SecurityException ignored) {
                // An authorization change can race with registration. The next resume rechecks it.
            }
        }
    }

    private void showTestResult(int message, boolean error, Object... arguments) {
        testStatus.setVisibility(View.VISIBLE);
        testStatus.setTextColor(error ? ERROR : MUTED);
        testStatus.setText(getString(message, arguments));
    }

    private void showSavedStatus() {
        syncStatus.setText(SyncSettings.preferences(this).getString(
            SyncSettings.STATUS, getString(R.string.status_setup)));
        refreshSyncControls();
    }

    private void showReceiverAddress(String host) {
        hostInput.setText(String.format(Locale.ROOT, "%s:%d", host, SyncSettings.PORT));
    }

    private LinearLayout card(int headingText) {
        LinearLayout card = column();
        card.setPadding(dp(16), dp(16), dp(16), dp(16));
        card.setBackground(shape(Color.WHITE, BORDER, 16));
        TextView heading = label(headingText, 18, INK, true);
        heading.setAccessibilityHeading(true);
        add(card, heading, 0);
        return card;
    }

    private TextView label(int text, int size, int color, boolean bold) {
        TextView view = new TextView(this);
        if (text != 0) {
            view.setText(text);
        }
        view.setTextSize(size);
        view.setTextColor(color);
        if (bold) {
            view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        }
        return view;
    }

    private EditText field(int id, int hint, int inputType) {
        EditText view = new EditText(this);
        view.setId(id);
        view.setSingleLine(true);
        view.setInputType(inputType);
        view.setTextSize(15);
        view.setTextColor(INK);
        view.setHintTextColor(MUTED);
        view.setHint(hint);
        view.setPadding(dp(12), dp(8), dp(12), dp(8));
        view.setMinHeight(dp(48));
        view.setBackground(shape(FIELD, BORDER, 9));
        return view;
    }

    private Button button(int text, boolean filled) {
        Button view = new Button(this);
        view.setText(text);
        view.setAllCaps(false);
        view.setTextSize(14);
        view.setTextColor(new ColorStateList(
            new int[][] {{-android.R.attr.state_enabled}, {}},
            new int[] {filled ? 0xffd8e5ff : MUTED, filled ? Color.WHITE : ACCENT}));
        view.setMinHeight(dp(48));
        view.setPadding(dp(12), dp(6), dp(12), dp(6));
        view.setBackground(new RippleDrawable(ColorStateList.valueOf(0x242457c6),
            shape(filled ? ACCENT : FIELD, filled ? ACCENT : BORDER, 9),
            shape(Color.WHITE, Color.WHITE, 9)));
        return view;
    }

    private GradientDrawable shape(int fill, int stroke, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(dp(radius));
        drawable.setStroke(dp(1), stroke);
        return drawable;
    }

    private LinearLayout actionRow(Button first, Button second) {
        LinearLayout row = row();
        row.addView(first, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        LinearLayout.LayoutParams trailing = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1);
        trailing.setMarginStart(dp(8));
        row.addView(second, trailing);
        return row;
    }

    private LinearLayout row() {
        LinearLayout view = new LinearLayout(this);
        view.setOrientation(LinearLayout.HORIZONTAL);
        view.setGravity(Gravity.CENTER_VERTICAL);
        return view;
    }

    private LinearLayout column() {
        LinearLayout view = new LinearLayout(this);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }

    private void add(LinearLayout parent, View child, int topMargin) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(topMargin);
        parent.addView(child, params);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
