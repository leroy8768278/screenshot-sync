package local.snapsync.android;

import android.os.Build;
import android.view.View;
import android.view.WindowInsets;
import android.widget.TextView;

import com.journeyapps.barcodescanner.CaptureActivity;
import com.journeyapps.barcodescanner.DecoratedBarcodeView;

public final class PairingScanActivity extends CaptureActivity {
    @Override
    protected DecoratedBarcodeView initializeContent() {
        setContentView(R.layout.pairing_scanner);
        SyncSettings.Pairing pairing = SyncSettings.read(this);
        TextView heading = findViewById(R.id.scan_heading);
        heading.setText(pairing.isVerified() ? R.string.scan_switch_mac : R.string.scan_first_title);
        if (pairing.isVerified()) {
            TextView current = findViewById(R.id.scan_destination);
            current.setText(getString(R.string.scan_current_mac, pairing.mac().displayName()));
            current.setVisibility(View.VISIBLE);
        }
        findViewById(R.id.scan_cancel).setOnClickListener(view -> finish());

        View root = findViewById(R.id.scan_root);
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            root.setOnApplyWindowInsetsListener((view, insets) -> {
                var bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
                return insets;
            });
        } else {
            root.setFitsSystemWindows(true);
        }
        return findViewById(R.id.pairing_camera);
    }
}
