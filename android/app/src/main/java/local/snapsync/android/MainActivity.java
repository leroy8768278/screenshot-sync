package local.snapsync.android;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
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
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.InputMethodManager;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;
import android.util.Size;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.google.zxing.client.android.Intents;
import com.journeyapps.barcodescanner.ScanOptions;

import java.io.IOException;
import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int REQUEST_PHOTOS = 1;
    private static final int PICK_MEDIA = 2;
    private static final int REQUEST_NOTIFICATIONS = 3;
    private static final int SCAN_PAIRING = 4;
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
    private final Runnable scanOnChange = () -> SyncScheduler.sync(this, SyncSettings.read(this));
    private final ContentObserver photos = new ContentObserver(handler) {
        @Override
        public void onChange(boolean selfChange) {
            handler.removeCallbacks(scanOnChange);
            handler.postDelayed(scanOnChange, 100);
        }
    };
    private final SharedPreferences.OnSharedPreferenceChangeListener statusListener = (prefs, key) -> {
        if (SyncSettings.STATUS.equals(key)) {
            showSavedStatus();
        } else if (SyncSettings.LIVE_ENABLED.equals(key)) {
            refreshSyncControls();
            if (!SyncSettings.liveEnabled(this)) {
                updateSyncMonitoring();
            }
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
    private Button scanButton;
    private Button switchMacButton;
    private Button connectButton;
    private Button connectionSettings;
    private Button disconnectButton;
    private Button requestPermissionButton;
    private Button openSettingsButton;
    private Button chooseMediaButton;
    private Button retryButton;
    private Button cancelSendButton;
    private Button syncControlButton;
    private Button liveSyncButton;
    private TextView manualStatus;
    private boolean observerRegistered;
    private boolean resumed;
    private boolean verifying;
    private boolean editingConnection;
    private boolean migrationAttempted;
    private String pickerSession = "";
    private String selectedSession = "";
    private ArrayList<Uri> selectedMedia = new ArrayList<>();
    private ManualSend manual;
    private DeviceChat chat;
    private ScrollView home;
    private OnBackInvokedCallback chatBack;

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
                selectedMedia = restored;
            }
        }
        chat.restore(savedInstanceState, pairing);
        SyncScheduler.configure(this, pairing);
        showSavedStatus();
    }

    void showChatPage(boolean show) {
        if (show == chat.isOpen()) { return; }
        View focused = getCurrentFocus();
        if (focused != null && focused.onCheckIsTextEditor()) {
            getSystemService(InputMethodManager.class).hideSoftInputFromWindow(focused.getWindowToken(), 0);
        }
        home.setVisibility(show ? View.GONE : View.VISIBLE);
        chat.page.setVisibility(show ? View.VISIBLE : View.GONE);
        if (show) { chat.page.requestFocus(); }
        if (Build.VERSION.SDK_INT >= 33) {
            if (show) {
                chatBack = chat::returnHome;
                getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    OnBackInvokedDispatcher.PRIORITY_DEFAULT, chatBack);
            } else {
                getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(chatBack);
                chatBack = null;
            }
        }
    }

    @Override
    @SuppressLint("GestureBackNavigation") // The window callback above handles API 33+.
    public void onBackPressed() {
        if (chat.isOpen()) { chat.returnHome(); }
        else { super.onBackPressed(); }
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        if (chat != null) { chat.observeTouch(event); }
        return super.dispatchTouchEvent(event);
    }

    @Override
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        chat.save(state);
        state.putString("picker_session", pickerSession);
        state.putString("selected_session", selectedSession);
        state.putParcelableArrayList("selected_images", selectedMedia);
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
        resumed = true;
        chat.foreground(true);
        refreshPermissions();
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        SyncScheduler.configure(this, pairing);
        if (pairing.isConfigured() && !pairing.isVerified() && !migrationAttempted) {
            migrationAttempted = true;
            verifyConnection(Collections.singletonList(pairing.host()), pairing.code());
        }
        updateSyncMonitoring();
    }

    @Override
    protected void onPause() {
        resumed = false;
        chat.foreground(false);
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
        chat.close();
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
            updateSyncMonitoring();
        } else if (requestCode == REQUEST_NOTIFICATIONS) {
            updateSyncMonitoring();
        }
    }

    private View buildContent() {
        FrameLayout screens = new FrameLayout(this);
        screens.setBackgroundColor(BACKGROUND);
        home = new ScrollView(this);
        home.setFillViewport(true);
        screens.addView(home);
        screens.setOnApplyWindowInsetsListener((view, insets) -> {
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
        home.addView(centered, new ScrollView.LayoutParams(
            ScrollView.LayoutParams.MATCH_PARENT, ScrollView.LayoutParams.WRAP_CONTENT));

        LinearLayout page = column();
        page.setFocusableInTouchMode(true);
        page.setPadding(dp(20), dp(26), dp(20), dp(26));
        int contentWidth = getResources().getDisplayMetrics().widthPixels;
        FrameLayout.LayoutParams pageParams = new FrameLayout.LayoutParams(
            Math.min(contentWidth, dp(580)), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        centered.addView(page, pageParams);

        LinearLayout heading = row();
        heading.setGravity(Gravity.START | Gravity.TOP);
        TextView title = label(R.string.app_name, 30, INK, true);
        title.setAccessibilityHeading(true);
        heading.addView(title);
        TextView version = label(0, 14, MUTED, false);
        version.setText(getString(R.string.app_version, BuildConfig.VERSION_NAME));
        version.setPaddingRelative(dp(8), 0, 0, 0);
        heading.addView(version);
        add(page, heading, 0);
        add(page, label(R.string.subtitle, 14, MUTED, false), 6);
        pairingPanel = pairingCard();
        syncPanel = statusCard();
        add(page, pairingPanel, 20);
        add(page, syncPanel, 12);
        screens.addView(chat.page);
        return screens;
    }

    private LinearLayout pairingCard() {
        LinearLayout card = card(R.string.connect_title);
        add(card, label(R.string.connect_help, 13, MUTED, false), 8);
        scanButton = button(R.string.scan_pairing, true);
        scanButton.setOnClickListener(view -> scanPairingCode());
        add(card, scanButton, 12);
        testStatus = label(0, 13, MUTED, false);
        testStatus.setVisibility(View.GONE);
        testStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(card, testStatus, 10);
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

        connectButton = button(R.string.manual_pairing, false);
        connectButton.setOnClickListener(view -> {
            Input input = readInput();
            if (input != null) {
                verifyConnection(Collections.singletonList(input.host()), input.code());
            }
        });
        add(card, connectButton, 12);
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
        switchMacButton = button(R.string.scan_switch_mac, false);
        switchMacButton.setOnClickListener(view -> scanPairingCode());
        add(destination, switchMacButton, 10);
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
        chat = new DeviceChat(this);
        add(page, chat.entry, 12);

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
        liveSyncButton = button(R.string.live_start, false);
        liveSyncButton.setOnClickListener(view -> toggleLiveSync());
        add(card, liveSyncButton, 8);
        add(page, card, 12);

        chooseMediaButton = button(R.string.pick_media, true);
        chooseMediaButton.setOnClickListener(view -> openMediaPicker());
        add(page, chooseMediaButton, 12);
        manualStatus = label(0, 13, MUTED, false);
        manualStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        manualStatus.setVisibility(View.GONE);
        add(page, manualStatus, 8);
        retryButton = button(R.string.manual_retry, false);
        retryButton.setOnClickListener(view -> confirmMedia());
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

    private void scanPairingCode() {
        Intent capture = new ScanOptions()
            .setCaptureActivity(PairingScanActivity.class)
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setPrompt(getString(R.string.scan_prompt))
            .setOrientationLocked(false)
            .setBeepEnabled(false)
            .addExtra(Intents.Scan.SHOW_MISSING_CAMERA_PERMISSION_DIALOG, false)
            .createScanIntent(this);
        startActivityForResult(capture, SCAN_PAIRING);
    }

    private void handlePairingScan(int result, Intent data) {
        if (data == null) {
            return;
        }
        if (result != RESULT_OK && !data.getBooleanExtra(Intents.Scan.MISSING_CAMERA_PERMISSION, false)) {
            return;
        }
        editingConnection = true;
        refreshSyncControls();
        pairingPanel.post(() -> pairingPanel.requestRectangleOnScreen(
            new Rect(0, 0, pairingPanel.getWidth(), dp(200)), false));
        if (result != RESULT_OK) {
            showTestResult(R.string.scan_permission, true);
            return;
        }
        try {
            PairingCode pairing = PairingCode.parse(data.getStringExtra(Intents.Scan.RESULT));
            verifyConnection(pairing.hosts(), pairing.token());
        } catch (IOException invalid) {
            showTestResult(R.string.scan_invalid, true);
        }
    }

    private void verifyConnection(List<String> hosts, String code) {
        if (verifying) {
            return;
        }
        verifying = true;
        refreshSyncControls();
        showTestResult(R.string.status_testing, false);
        connectionExecutor.execute(() -> {
            String verifiedHost = null;
            int response = 0;
            for (String host : hosts) {
                if (Thread.currentThread().isInterrupted()) {
                    return;
                }
                try (ReceiverConnection receiver = new ReceiverConnection(getApplicationContext(), host, code)) {
                    response = receiver.test();
                    if (response == 200) {
                        verifiedHost = host;
                        break;
                    }
                } catch (IOException unavailable) {
                    // Try the next network interface advertised by the same Mac.
                }
            }
            String destination = verifiedHost;
            int result = response;
            long verifiedAt = System.currentTimeMillis();
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) {
                    return;
                }
                verifying = false;
                switch (result) {
                    case 200 -> saveVerified(new Input(destination, code), verifiedAt);
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

        connectionExecutor.execute(() -> {
            if (!SyncSettings.isCurrent(this, pairing)) {
                return;
            }
            try (ReceiverConnection receiver = new ReceiverConnection(this, pairing.host(), pairing.code())) {
                receiver.reportDevice(pairing.deviceId());
            } catch (IOException unavailable) {
                // Media uploads also carry this profile if the receiver is unavailable now.
            }
        });

        showReceiverAddress(input.host());
        codeInput.setText(input.code());
        getSystemService(InputMethodManager.class).hideSoftInputFromWindow(hostInput.getWindowToken(), 0);
        hostInput.clearFocus();
        codeInput.clearFocus();
        editingConnection = false;
        testStatus.setVisibility(View.GONE);
        SyncScheduler.configure(this, pairing);
        refreshPermissions();
        updateSyncMonitoring();
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
                updateSyncMonitoring();
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
        updateSyncMonitoring();
    }

    private void toggleLiveSync() {
        if (SyncSettings.liveEnabled(this)) {
            SyncSettings.setLiveEnabled(this, false);
            return;
        }
        SyncSettings.setLiveEnabled(this, true);
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS }, REQUEST_NOTIFICATIONS);
        } else {
            updateSyncMonitoring();
        }
    }

    private void updateSyncMonitoring() {
        if (!resumed) {
            return;
        }
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        boolean live = ScreenshotMonitor.start(this, pairing);
        boolean fallback = !live && ScreenshotScan.canRun(this, pairing);
        updateObserver(fallback);
        if (fallback) {
            SyncScheduler.sync(this, pairing);
        }
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
    }

    private void refreshSyncControls() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        chat.bind(pairing);
        boolean connected = pairing.isVerified();
        boolean configured = pairing.isConfigured();
        syncPanel.setVisibility(connected ? View.VISIBLE : View.GONE);
        pairingPanel.setVisibility(connected && !editingConnection ? View.GONE : View.VISIBLE);
        boolean sending = manual != null;
        scanButton.setEnabled(!verifying && !sending);
        switchMacButton.setVisibility(editingConnection ? View.GONE : View.VISIBLE);
        switchMacButton.setEnabled(!verifying && !sending);
        connectButton.setEnabled(!verifying && !sending);
        disconnectButton.setVisibility(configured ? View.VISIBLE : View.GONE);
        disconnectButton.setEnabled(!verifying && !sending);
        connectionSettings.setEnabled(!sending && !verifying);
        chooseMediaButton.setEnabled(connected && !sending && !verifying);
        retryButton.setVisibility(!selectedMedia.isEmpty() && !sending ? View.VISIBLE : View.GONE);
        retryButton.setEnabled(connected && !verifying);
        cancelSendButton.setVisibility(sending ? View.VISIBLE : View.GONE);
        syncControlButton.setEnabled(!verifying);
        syncControlButton.setText(pairing.paused() ? R.string.resume_sync : R.string.stop_sync);
        PhotoAccess access = PhotoAccess.current(this);
        boolean live = SyncSettings.liveEnabled(this);
        liveSyncButton.setText(live ? R.string.live_stop : R.string.live_start);
        liveSyncButton.setEnabled(!verifying && (live || !pairing.paused() && access == PhotoAccess.FULL));
        if (!connected) {
            return;
        }

        String timestamp = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
            .format(new Date(pairing.connectedAt()));
        connectedReceiver.setText(getString(R.string.connection_summary, pairing.host(), SyncSettings.PORT, timestamp));
        syncMode.setText(pairing.paused() ? R.string.automatic_paused
            : access == PhotoAccess.FULL ? R.string.automatic_running : R.string.automatic_needs_permission);
    }

    @SuppressWarnings("deprecation")
    private void openMediaPicker() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (!pairing.isVerified()) {
            return;
        }
        pickerSession = sessionKey(pairing);
        if (Build.VERSION.SDK_INT >= 33) {
            Intent photoPicker = new Intent(MediaStore.ACTION_PICK_IMAGES)
                .putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit());
            try {
                startActivityForResult(photoPicker, PICK_MEDIA);
                return;
            } catch (ActivityNotFoundException unavailable) {
                // Some devices provide the document picker only.
            }
        }
        Intent documents = new Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_MIME_TYPES, new String[] {"image/*", "video/*"})
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        try {
            startActivityForResult(documents, PICK_MEDIA);
        } catch (ActivityNotFoundException unavailable) {
            pickerSession = "";
            showManualStatus(getString(R.string.manual_picker_missing));
        }
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (chat.result(request, result, data)) { return; }
        if (request == SCAN_PAIRING) {
            handlePairingScan(result, data);
            return;
        }
        if (request != PICK_MEDIA) {
            return;
        }
        String session = pickerSession;
        pickerSession = "";
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (result != RESULT_OK || data == null || !pairing.isVerified() || !session.equals(sessionKey(pairing))) {
            return;
        }
        LinkedHashSet<Uri> media = new LinkedHashSet<>();
        addSelectedUri(media, data.getData());
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                addSelectedUri(media, clip.getItemAt(i).getUri());
            }
        }
        if (media.isEmpty()) {
            return;
        }
        selectedSession = session;
        selectedMedia = new ArrayList<>(media);
        confirmMedia();
    }

    private static void addSelectedUri(LinkedHashSet<Uri> media, Uri uri) {
        if (uri != null && "content".equals(uri.getScheme())) {
            media.add(uri);
        }
    }

    private void confirmMedia() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (selectedMedia.isEmpty() || !pairing.isVerified() || !selectedSession.equals(sessionKey(pairing))) {
            return;
        }
        List<Uri> selection = new ArrayList<>(selectedMedia);
        LinearLayout previewContent = column();
        previewContent.setPadding(dp(20), dp(8), dp(20), dp(8));
        TextView message = label(0, 14, INK, false);
        message.setText(getString(R.string.manual_confirm_receiver, pairing.host(), SyncSettings.PORT, selection.size()));
        add(previewContent, message, 0);
        HorizontalScrollView thumbnails = new HorizontalScrollView(this);
        LinearLayout previews = row();
        thumbnails.addView(previews);
        add(previewContent, thumbnails, 10);
        CancellationSignal cancellation = new CancellationSignal();
        for (Uri uri : selection.subList(0, Math.min(selection.size(), 6))) {
            FrameLayout preview = new FrameLayout(this);
            preview.setBackground(shape(FIELD, BORDER, 8));
            preview.setClipToOutline(true);
            ImageView thumbnail = new ImageView(this);
            thumbnail.setScaleType(ImageView.ScaleType.CENTER_CROP);
            preview.addView(thumbnail, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
            TextView videoBadge = label(R.string.manual_video, 10, Color.WHITE, true);
            videoBadge.setVisibility(View.GONE);
            videoBadge.setPadding(dp(5), dp(1), dp(5), dp(1));
            videoBadge.setBackground(shape(INK, INK, 4));
            FrameLayout.LayoutParams badgeParams = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.END);
            badgeParams.setMarginEnd(dp(3));
            badgeParams.bottomMargin = dp(3);
            preview.addView(videoBadge, badgeParams);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(dp(62), dp(62));
            params.setMarginEnd(dp(8));
            previews.addView(preview, params);
            previewExecutor.execute(() -> {
                try {
                    var resolver = getContentResolver();
                    String type = resolver.getType(uri);
                    if (type != null && type.startsWith("video/")) {
                        runOnUiThread(() -> {
                            if (!cancellation.isCanceled()) {
                                videoBadge.setVisibility(View.VISIBLE);
                            }
                        });
                    }
                    var bitmap = resolver.loadThumbnail(uri, new Size(dp(62), dp(62)), cancellation);
                    runOnUiThread(() -> {
                        if (!cancellation.isCanceled()) {
                            thumbnail.setImageBitmap(bitmap);
                        }
                    });
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
        selectedMedia = new ArrayList<>(result.pending());
        String summary = getString(R.string.manual_result, result.sent(), result.alreadySynced(), selectedMedia.size());
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
        selectedMedia.clear();
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

    TextView label(int text, int size, int color, boolean bold) {
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

    Button button(int text, boolean filled) {
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

    GradientDrawable shape(int fill, int stroke, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(dp(radius));
        drawable.setStroke(dp(1), stroke);
        return drawable;
    }

    LinearLayout actionRow(Button first, Button second) {
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

    LinearLayout column() {
        LinearLayout view = new LinearLayout(this);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }

    void add(LinearLayout parent, View child, int topMargin) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(topMargin);
        parent.addView(child, params);
    }

    int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
