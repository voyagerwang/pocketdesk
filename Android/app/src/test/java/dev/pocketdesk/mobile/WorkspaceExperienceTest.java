/**
 * [INPUT]: Android 35 沙箱和真实工作台 Activity。
 * [OUTPUT]: 控制台二维码接入、重启恢复、坏码不破坏连接、正方形扫描回归。
 * [POS]: 不向电脑发送命令的客户端集成验证。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.*;
import org.robolectric.annotation.Config;
import android.content.Intent;
import android.webkit.WebView;
import android.view.*;
import com.journeyapps.barcodescanner.*;
import static org.junit.Assert.*;
import static org.robolectric.Shadows.shadowOf;
@RunWith(RobolectricTestRunner.class) @Config(sdk=35)
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
public class WorkspaceExperienceTest {
    static final String URL="http://192.168.1.2:46387/?token=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG";
    private WebView web(View v){if(v instanceof WebView)return (WebView)v;if(v instanceof ViewGroup)for(int i=0;i<((ViewGroup)v).getChildCount();i++){WebView r=web(((ViewGroup)v).getChildAt(i));if(r!=null)return r;}return null;}
    @Test public void pcQrLoadsFullWorkbenchAndRestoresAfterRestart(){
        try(var c=Robolectric.buildActivity(MainActivity.class).setup()){
            c.get().onActivityResult(49374,-1,new Intent().putExtra("SCAN_RESULT",URL));
            WebView w=web(c.get().getWindow().getDecorView());assertEquals(URL,w.getUrl());assertTrue(w.getSettings().getJavaScriptEnabled());assertTrue(w.getSettings().getDomStorageEnabled());
            c.get().connect("https://example.com/?token=abcdefghijklmnopqrstuvwxyz");assertEquals(URL,w.getUrl());
        }
        try(var c=Robolectric.buildActivity(MainActivity.class).setup()){assertEquals(URL,web(c.get().getWindow().getDecorView()).getUrl());}
    }
    @Test public void connectedWorkbenchHasNoNativeHeaderOrEmptyStatusGap(){
        try(var c=Robolectric.buildActivity(MainActivity.class).setup()){
            MainActivity app=c.get();app.connect(URL);WebView w=web(app.getWindow().getDecorView());
            shadowOf(w).getWebViewClient().onPageFinished(w,URL);
            android.widget.LinearLayout root=(android.widget.LinearLayout)w.getParent();
            root.measure(View.MeasureSpec.makeMeasureSpec(390,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(844,View.MeasureSpec.EXACTLY));root.layout(0,0,390,844);
            assertEquals(0,w.getTop());
            for(int i=0;i<root.getChildCount();i++)if(root.getChildAt(i)!=w&&!"native-navigation".equals(root.getChildAt(i).getTag()))assertEquals(View.GONE,root.getChildAt(i).getVisibility());
            assertTrue(w.getSettings().getUserAgentString().contains("PocketDeskAndroid/"));
        }
    }
    @Test public void onlyUserMainFrameNavigationCanOpenConnectionSettings(){
        try(var c=Robolectric.buildActivity(MainActivity.class).setup()){
            MainActivity app=c.get();app.connect(URL);WebView w=web(app.getWindow().getDecorView());
            android.webkit.WebResourceRequest click=new android.webkit.WebResourceRequest(){
                public android.net.Uri getUrl(){return android.net.Uri.parse("pocketdesk://settings");}
                public boolean isForMainFrame(){return true;}public boolean isRedirect(){return false;}
                public boolean hasGesture(){return true;}public String getMethod(){return "GET";}
                public java.util.Map<String,String> getRequestHeaders(){return java.util.Collections.emptyMap();}
            };
            assertTrue(shadowOf(w).getWebViewClient().shouldOverrideUrlLoading(w,click));
            assertEquals(ConnectionActivity.class.getName(),shadowOf(app).getNextStartedActivity().getComponent().getClassName());
        }
    }
    @Test public void lockShortcutRequiresExplicitGestureAndPreservesTheme()throws Exception{
        RuntimeEnvironment.getApplication().getSharedPreferences("workspace",0).edit().putString("url",URL).commit();
        try(var c=Robolectric.buildActivity(MainActivity.class).setup()){
            MainActivity app=c.get();WebView web=findWebForShortcut(app.getWindow().getDecorView());
            assertNull(app.getWindow().getDecorView().findViewWithTag("native-navigation"));
            for(boolean gesture:new boolean[]{false,true}){
                android.webkit.WebResourceRequest request=new android.webkit.WebResourceRequest(){
                    public android.net.Uri getUrl(){return android.net.Uri.parse("pocketdesk://unlock?theme=muji");}
                    public boolean isForMainFrame(){return true;}public boolean isRedirect(){return false;}public boolean hasGesture(){return gesture;}
                    public String getMethod(){return "GET";}public java.util.Map<String,String>getRequestHeaders(){return java.util.Collections.emptyMap();}
                };
                assertTrue(shadowOf(web).getWebViewClient().shouldOverrideUrlLoading(web,request));
                Intent launched=shadowOf(app).getNextStartedActivity();
                if(!gesture)assertNull(launched);else {
                    assertEquals(UnlockActivity.class.getName(),launched.getComponent().getClassName());assertTrue(launched.getBooleanExtra("quickUnlock",false));
                    assertEquals("muji",app.getSharedPreferences("appearance",0).getString("theme",""));
                }
            }
        }
    }
    private WebView findWebForShortcut(View view){if(view instanceof WebView)return(WebView)view;if(view instanceof ViewGroup)for(int i=0;i<((ViewGroup)view).getChildCount();i++){WebView found=findWebForShortcut(((ViewGroup)view).getChildAt(i));if(found!=null)return found;}return null;}
    @Test public void downloadKeepsRealUnicodeAndApkNames(){
        assertEquals("PocketDesk-0.2.0.apk",MainActivity.downloadName(URL,"attachment; filename=\"download\"; filename*=UTF-8''PocketDesk-0.2.0.apk","application/octet-stream"));
        assertEquals("测试.txt",MainActivity.downloadName(URL,"attachment; filename*=UTF-8''%E6%B5%8B%E8%AF%95.txt","application/octet-stream"));
    }
    @Test public void connectionRejectsForeignOriginsAndMalformedInvites()throws Exception{
        WorkspaceConnection c=new WorkspaceConnection(URL);assertTrue(c.owns("http://192.168.1.2:46387/api/phone-files/download?ticket=x"));
        assertFalse(c.owns("http://192.168.1.2:46387@evil.com/"));assertFalse(c.owns("http://192.168.1.2:46388/"));assertFalse(c.owns("file:///sdcard/private"));
        for(String bad:new String[]{"http://192.168.1.2:46387/","javascript:alert(1)","http://8.8.8.8/?token=abcdefghijklmnopqrstuvwxyz"})try{new WorkspaceConnection(bad);fail(bad);}catch(Exception expected){}
    }
    private DecoratedBarcodeView scanner(View v){if(v instanceof DecoratedBarcodeView)return (DecoratedBarcodeView)v;if(v instanceof ViewGroup)for(int i=0;i<((ViewGroup)v).getChildCount();i++){DecoratedBarcodeView r=scanner(((ViewGroup)v).getChildAt(i));if(r!=null)return r;}return null;}
    @Test @Config(qualifiers="w390dp-h844dp-mdpi") public void renderWorkbenchIntro()throws Exception{
        RuntimeEnvironment.getApplication().getSharedPreferences("workspace",0).edit().clear().commit();
        try(var c=Robolectric.buildActivity(MainActivity.class).setup()){snapshot(c.get(),"/tmp/pd-workspace-home.png");}
    }
    private void snapshot(android.app.Activity app,String path)throws Exception{
        View root=app.findViewById(android.R.id.content);root.measure(View.MeasureSpec.makeMeasureSpec(390,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(844,View.MeasureSpec.EXACTLY));root.layout(0,0,390,844);
        android.graphics.Bitmap b=android.graphics.Bitmap.createBitmap(390,844,android.graphics.Bitmap.Config.ARGB_8888);root.draw(new android.graphics.Canvas(b));
        try(var out=new java.io.FileOutputStream(path)){b.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}
    }
    @Test @Config(qualifiers="w390dp-h844dp-mdpi") public void scannerPreviewIsSquare()throws Exception{
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(android.Manifest.permission.CAMERA);
        try(var c=Robolectric.buildActivity(SquareCaptureActivity.class,new Intent("com.google.zxing.client.android.SCAN")).setup()){
            DecoratedBarcodeView v=scanner(c.get().getWindow().getDecorView());assertEquals(v.getLayoutParams().width,v.getLayoutParams().height);assertTrue(v.getLayoutParams().width>0);snapshot(c.get(),"/tmp/pd-workspace-scanner.png");
        }
    }
}
