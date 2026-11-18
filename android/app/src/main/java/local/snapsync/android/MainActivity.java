package local.snapsync.android;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.database.ContentObserver;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.text.method.PasswordTransformationMethod;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;

import java.io.IOException;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int REQUEST_PHOTOS = 1;
    private static final int BACKGROUND = 0xfff2f5f1;
    private static final int INK = 0xff182b24;
    private static final int MUTED = 0xff54645b;
    private static final int ACCENT = 0xff24604f;
    private static final int BORDER = 0xffdbe5dd;
    private static final int FIELD = 0xfff7faf8;
    private static final int ERROR = 0xffa3262e;
    private static final int HOST_ID = View.generateViewId();
    private static final int CODE_ID = View.generateViewId();
    private static final int AUTO_ID = View.generateViewId();
    private static final int HISTORY_ID = View.generateViewId();

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService testExecutor = Executors.newSingleThreadExecutor();
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
    private Switch automaticInput;
    private Switch historyInput;
    private TextView testStatus;
    private TextView syncStatus;
    private TextView permissionStatus;
    private Button testButton;
    private Button requestPermissionButton;
    private Button openSettingsButton;
    private Button syncButton;
    private boolean observerRegistered;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
        }
        setContentView(buildContent());

        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (pairing.isConfigured()) {
            showReceiverAddress(pairing.host());
            codeInput.setText(pairing.code());
        }
        automaticInput.setChecked(pairing.automatic());
        historyInput.setChecked(pairing.history());
        SyncScheduler.configure(this, pairing);
        showSavedStatus();
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
        testExecutor.shutdownNow();
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_PHOTOS) {
            refreshPermissions();
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
        add(page, pairingCard(), 22);
        add(page, statusCard(), 12);
        add(page, label(R.string.background_hint, 12, MUTED, false), 14);
        return scroll;
    }

    private View pairingCard() {
        LinearLayout card = card(R.string.receiver);
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

        automaticInput = toggle(AUTO_ID, R.string.automatic);
        historyInput = toggle(HISTORY_ID, R.string.history);
        add(card, automaticInput, 12);
        add(card, historyInput, 0);

        testButton = button(R.string.test, false);
        testButton.setOnClickListener(view -> testConnection());
        Button save = button(R.string.save, true);
        save.setOnClickListener(view -> savePairing());
        add(card, actionRow(testButton, save), 12);
        testStatus = label(0, 13, MUTED, false);
        testStatus.setVisibility(View.GONE);
        testStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(card, testStatus, 10);
        return card;
    }

    private View statusCard() {
        LinearLayout card = card(R.string.status_title);
        syncStatus = label(R.string.status_setup, 14, INK, false);
        syncStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(card, syncStatus, 12);
        permissionStatus = label(R.string.permission_missing, 13, MUTED, false);
        add(card, permissionStatus, 8);
        requestPermissionButton = button(R.string.permission, false);
        requestPermissionButton.setOnClickListener(view -> requestPermissions(PhotoAccess.permissions(), REQUEST_PHOTOS));
        openSettingsButton = button(R.string.open_settings, false);
        openSettingsButton.setOnClickListener(view -> startActivity(new Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", getPackageName(), null))));
        add(card, actionRow(requestPermissionButton, openSettingsButton), 8);

        syncButton = button(R.string.sync, true);
        syncButton.setOnClickListener(view -> syncNow());
        add(card, syncButton, 12);
        return card;
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

    private void savePairing() {
        Input input = readInput();
        if (input == null) {
            return;
        }
        if (!SyncSettings.save(this, input.host(), input.code(), automaticInput.isChecked(), historyInput.isChecked())) {
            showTestResult(R.string.save_failed, true);
            return;
        }
        showReceiverAddress(input.host());
        codeInput.setText(input.code());
        InputMethodManager keyboard = getSystemService(InputMethodManager.class);
        keyboard.hideSoftInputFromWindow(hostInput.getWindowToken(), 0);
        hostInput.clearFocus();
        codeInput.clearFocus();

        SyncSettings.Pairing pairing = SyncSettings.read(this);
        SyncScheduler.configure(this, pairing);
        refreshPermissions();
        if (pairing.automatic() && PhotoAccess.current(this) != PhotoAccess.NONE) {
            SyncSettings.status(this, pairing, R.string.status_queued);
            SyncScheduler.sync(this, false);
        } else {
            SyncSettings.status(this, pairing, R.string.status_saved);
        }
    }

    private void testConnection() {
        Input input = readInput();
        if (input == null) {
            return;
        }
        testButton.setEnabled(false);
        showTestResult(R.string.status_testing, false);
        testExecutor.execute(() -> {
            int result;
            try {
                result = new ReceiverConnection(getApplicationContext(), input.host(), input.code()).test();
            } catch (IOException failure) {
                result = 0;
            }
            final int response = result;
            runOnUiThread(() -> {
                if (isDestroyed()) {
                    return;
                }
                testButton.setEnabled(true);
                switch (response) {
                    case 200 -> showTestResult(R.string.status_connected, false);
                    case 401, 403 -> showTestResult(R.string.status_bad_code, true);
                    case 0 -> showTestResult(R.string.status_network, true);
                    default -> showTestResult(R.string.status_rejected, true, response);
                }
            });
        });
    }

    private void syncNow() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (!pairing.isConfigured()) {
            syncStatus.setText(R.string.status_save_first);
            return;
        }
        if (PhotoAccess.current(this) == PhotoAccess.NONE) {
            syncStatus.setText(R.string.permission_missing);
            return;
        }
        SyncSettings.status(this, pairing, R.string.status_queued);
        SyncScheduler.sync(this, true);
    }

    private void triggerForegroundSync() {
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        if (pairing.isConfigured() && pairing.automatic() && PhotoAccess.current(this) != PhotoAccess.NONE) {
            SyncScheduler.sync(this, false);
        }
    }

    private void refreshPermissions() {
        PhotoAccess access = PhotoAccess.current(this);
        permissionStatus.setText(switch (access) {
            case FULL -> R.string.permission_full;
            case LIMITED -> R.string.permission_partial;
            case NONE -> R.string.permission_missing;
        });
        requestPermissionButton.setText(access == PhotoAccess.LIMITED
            ? R.string.permission_button_partial : R.string.permission);
        requestPermissionButton.setVisibility(access == PhotoAccess.FULL ? View.GONE : View.VISIBLE);
        openSettingsButton.setVisibility(access == PhotoAccess.FULL ? View.GONE : View.VISIBLE);
        syncButton.setEnabled(SyncSettings.read(this).isConfigured() && access != PhotoAccess.NONE);
        updateObserver(access != PhotoAccess.NONE);
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

    private Switch toggle(int id, int text) {
        Switch view = new Switch(this);
        view.setId(id);
        view.setText(text);
        view.setTextSize(14);
        view.setTextColor(INK);
        view.setMinHeight(dp(46));
        return view;
    }

    private Button button(int text, boolean filled) {
        Button view = new Button(this);
        view.setText(text);
        view.setAllCaps(false);
        view.setTextSize(14);
        view.setTextColor(new ColorStateList(
            new int[][] {{-android.R.attr.state_enabled}, {}},
            new int[] {filled ? 0xffd3e2da : MUTED, filled ? Color.WHITE : ACCENT}));
        view.setMinHeight(dp(48));
        view.setPadding(dp(12), dp(6), dp(12), dp(6));
        view.setBackground(new RippleDrawable(ColorStateList.valueOf(0x24315f48),
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
