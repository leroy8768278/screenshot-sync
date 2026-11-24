package local.snapsync.android;

import android.os.Build;
import android.view.WindowInsets;
import android.widget.FrameLayout;
import android.widget.TextView;

import com.journeyapps.barcodescanner.CaptureActivity;
import com.journeyapps.barcodescanner.DecoratedBarcodeView;

public final class PairingScanActivity extends CaptureActivity {
    @Override
    protected DecoratedBarcodeView initializeContent() {
        DecoratedBarcodeView scanner = super.initializeContent();
        TextView prompt = scanner.getStatusView();
        int padding = Math.round(12 * getResources().getDisplayMetrics().density);
        prompt.setBackgroundColor(0xb3172641);
        prompt.setPadding(padding, padding / 2, padding, padding / 2);
        scanner.setOnApplyWindowInsetsListener((view, insets) -> {
            int bottom = Build.VERSION.SDK_INT >= 30
                ? insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()).bottom
                : insets.getSystemWindowInsetBottom();
            FrameLayout.LayoutParams layout = (FrameLayout.LayoutParams) prompt.getLayoutParams();
            layout.bottomMargin = bottom + padding;
            prompt.setLayoutParams(layout);
            return insets;
        });
        return scanner;
    }
}
