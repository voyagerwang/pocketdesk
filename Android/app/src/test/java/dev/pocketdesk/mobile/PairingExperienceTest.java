/**
 * [INPUT]: Robolectric Android 35 与真实 UnlockActivity，使用本地空配对存储。
 * [OUTPUT]: 首次连接、相机权限拒绝/授权、扫码取消和错误二维码恢复回归；导出窄屏/大字截图。
 * [POS]: 安卓界面沙箱验证，不连接 Mac、不触发解锁或手机硬件相机。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;

import android.Manifest;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.TextView;
import java.io.FileOutputStream;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.GraphicsMode;
import org.robolectric.shadows.ShadowAlertDialog;
import static org.robolectric.Shadows.shadowOf;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
public class PairingExperienceTest {
    private Button find(View view, String text) {
        if (view instanceof Button && ((Button)view).getText().toString().equals(text)) return (Button)view;
        if (view instanceof ViewGroup) for (int i=0; i<((ViewGroup)view).getChildCount(); i++) {
            Button result = find(((ViewGroup)view).getChildAt(i), text); if(result != null) return result;
        }
        return null;
    }
    private boolean contains(View view, String text) {
        if (view.getVisibility() != View.VISIBLE) return false;
        if (view instanceof TextView && ((TextView)view).getText().toString().contains(text)) return true;
        if (view instanceof ViewGroup) for (int i=0; i<((ViewGroup)view).getChildCount(); i++)
            if (contains(((ViewGroup)view).getChildAt(i),text)) return true;
        return false;
    }
    @Test public void firstRunHasOneConnectionPathAndActionableHelp() {
        try (var controller = Robolectric.buildActivity(UnlockActivity.class).setup()) {
            UnlockActivity app=controller.get(); View root=app.getWindow().getDecorView();
            assertTrue(contains(root,"连接你的 Mac"));
            assertEquals(View.GONE,find(root,"解锁电脑").getVisibility());
            assertNull(find(root,"打开普通网页功能"));
            find(root,"找不到配对码 / 无法扫码").performClick();
            AlertDialog dialog=ShadowAlertDialog.getLatestAlertDialog();
            assertTrue(contains(dialog.getWindow().getDecorView(),"配套的 Mac 版本"));
            assertNotNull(dialog.getButton(AlertDialog.BUTTON_NEUTRAL));
        }
    }
    @Test public void cameraDenialKeepsUserInAppWithRecovery() {
        try (var controller = Robolectric.buildActivity(UnlockActivity.class).setup()) {
            UnlockActivity app=controller.get();
            app.onRequestPermissionsResult(41,new String[]{Manifest.permission.CAMERA},new int[]{PackageManager.PERMISSION_DENIED});
            assertFalse(app.isFinishing());
            AlertDialog dialog=ShadowAlertDialog.getLatestAlertDialog();
            assertEquals("打开权限设置",dialog.getButton(AlertDialog.BUTTON_POSITIVE).getText().toString());
            assertEquals("粘贴配对链接",dialog.getButton(AlertDialog.BUTTON_NEUTRAL).getText().toString());
        }
    }
    @Test public void cameraGrantLaunchesBundledScanner() {
        shadowOf(RuntimeEnvironment.getApplication().getPackageManager()).setSystemFeature(PackageManager.FEATURE_CAMERA_ANY,true);
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.CAMERA);
        try (var controller = Robolectric.buildActivity(UnlockActivity.class).setup()) {
            UnlockActivity app=controller.get();
            find(app.getWindow().getDecorView(),"扫码连接电脑").performClick();
            Intent intent=shadowOf(app).getNextStartedActivityForResult().intent;
            assertEquals("dev.pocketdesk.mobile.SquareCaptureActivity",intent.getComponent().getClassName());
            assertFalse(app.isFinishing());
        }
    }
    @Test public void scannerActivityCanEnterItsLifecycle() {
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.CAMERA);
        try (var controller = Robolectric.buildActivity(dev.pocketdesk.mobile.SquareCaptureActivity.class,
                new Intent("com.google.zxing.client.android.SCAN")).setup()) {
            assertNotNull(controller.get().getWindow().getDecorView());
            assertFalse(controller.get().isFinishing());
        }
    }
    @Test public void wrongQrAndCancellationHaveRecoverableMessages() {
        try (var controller = Robolectric.buildActivity(UnlockActivity.class).setup()) {
            UnlockActivity app=controller.get();
            app.onActivityResult(49374,UnlockActivity.RESULT_OK,new Intent().putExtra("SCAN_RESULT","http://192.168.1.2:46387"));
            assertTrue(contains(app.getWindow().getDecorView(),"这是网页连接码"));
            app.onActivityResult(49374,UnlockActivity.RESULT_CANCELED,null);
            assertTrue(contains(app.getWindow().getDecorView(),"扫码未完成"));
            assertFalse(app.isFinishing());
        }
    }
    @Test @Config(qualifiers="w320dp-h640dp-mdpi") public void renderNarrowScreen() throws Exception { snapshot("/tmp/pd-pairing-320.png",320,640); }
    @Test @Config(qualifiers="w390dp-h844dp-mdpi") public void renderLargeText() throws Exception {
        RuntimeEnvironment.setFontScale(1.3f); snapshot("/tmp/pd-pairing-large-text.png",390,844);
    }
    private void snapshot(String path,int width,int height) throws Exception {
        try (var controller = Robolectric.buildActivity(UnlockActivity.class).setup()) {
            View root=controller.get().findViewById(android.R.id.content);
            root.measure(View.MeasureSpec.makeMeasureSpec(width,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(height,View.MeasureSpec.EXACTLY));
            root.layout(0,0,width,height);
            Bitmap bitmap=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888); root.draw(new Canvas(bitmap));
            try(FileOutputStream out=new FileOutputStream(path)){bitmap.compress(Bitmap.CompressFormat.PNG,100,out);}
            assertTrue(find(root,"扫码连接电脑").getBottom() <= height);
        }
    }
}
