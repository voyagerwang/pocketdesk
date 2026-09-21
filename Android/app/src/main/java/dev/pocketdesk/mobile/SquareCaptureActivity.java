/**
 * [INPUT]: ZXing CaptureActivity 的相机生命周期与解码能力。
 * [OUTPUT]: 带正方形相机预览和取景框的扫码页面。
 * [POS]: 工作台连接和可选解锁配对共用，不改变二维码协议。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import android.graphics.Color;
import android.view.Gravity;
import android.view.WindowInsets;
import android.widget.*;
import com.journeyapps.barcodescanner.*;
public final class SquareCaptureActivity extends CaptureActivity {
    @Override protected DecoratedBarcodeView initializeContent() {
        LinearLayout root=new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL); root.setBackgroundColor(Color.rgb(245,247,251));
        root.setOnApplyWindowInsetsListener((v,insets)->{android.graphics.Insets b=insets.getInsets(WindowInsets.Type.systemBars());v.setPadding(b.left,b.top,b.right,b.bottom);return insets;});
        TextView title=new TextView(this);title.setText("扫描电脑上的二维码");title.setTextSize(22);title.setTextColor(Color.rgb(28,39,57));title.setPadding(16,32,16,24);root.addView(title);
        int side=Math.round(Math.min(280, getResources().getConfiguration().screenWidthDp-48)*getResources().getDisplayMetrics().density);
        DecoratedBarcodeView scanner=new DecoratedBarcodeView(this);
        scanner.getStatusView().setVisibility(android.view.View.GONE);
        android.view.View outline=new android.view.View(this);
        android.graphics.drawable.GradientDrawable border=new android.graphics.drawable.GradientDrawable();border.setColor(Color.TRANSPARENT);border.setStroke(2,Color.WHITE);outline.setBackground(border);
        scanner.addView(outline,new FrameLayout.LayoutParams(side*4/5,side*4/5,Gravity.CENTER));
        scanner.getBarcodeView().setFramingRectSize(new Size(side*4/5,side*4/5));
        root.addView(scanner,new LinearLayout.LayoutParams(side,side));
        TextView note=new TextView(this);note.setText("将二维码放入方框内\n工作台二维码位于电脑控制台的“手机扫码连接”");note.setTextSize(16);note.setPadding(24,24,24,16);root.addView(note);
        Button back=new Button(this);back.setText("返回");back.setMinHeight(48);back.setOnClickListener(v->finish());root.addView(back);
        setContentView(root);return scanner;
    }
}
