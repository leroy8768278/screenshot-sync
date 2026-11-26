package local.snapsync.android;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.util.AttributeSet;

import com.journeyapps.barcodescanner.ViewfinderView;

/** Mark the same area the decoder actually inspects when the preview rotates or resizes. */
public final class PairingReticle extends ViewfinderView {
    private final Paint corners = new Paint(Paint.ANTI_ALIAS_FLAG);

    public PairingReticle(Context context, AttributeSet attrs) {
        super(context, attrs);
        setLaserVisibility(false);
        setMaskColor(0x690E1D18);
        corners.setStrokeCap(Paint.Cap.ROUND);
        corners.setStrokeWidth(3 * getResources().getDisplayMetrics().density);
        corners.setColor(0xFFB6F0CD);
    }

    @Override
    public void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        Rect frame = framingRect;
        if (frame == null) { return; }
        float arm = Math.min(frame.width() * 0.14f, 27 * getResources().getDisplayMetrics().density);
        drawCorner(canvas, frame.left, frame.top, arm, arm);
        drawCorner(canvas, frame.right, frame.top, -arm, arm);
        drawCorner(canvas, frame.left, frame.bottom, arm, -arm);
        drawCorner(canvas, frame.right, frame.bottom, -arm, -arm);
    }

    private void drawCorner(Canvas canvas, float x, float y, float dx, float dy) {
        canvas.drawLine(x, y, x + dx, y, corners);
        canvas.drawLine(x, y, x, y + dy, corners);
    }
}
