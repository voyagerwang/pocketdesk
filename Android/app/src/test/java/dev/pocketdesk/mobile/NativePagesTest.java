/**
 * [INPUT]: Android 35 原生页面与隔离的文件列表/连接资料。
 * [OUTPUT]: 原生文件导航、草稿页面保留意图、收件显示、下载地址边界与页面截图。
 * [POS]: 不连接真实电脑，不发起真实下载；不代替真机体验验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.*;
import org.robolectric.annotation.*;
import org.json.*;
import android.view.*;
import android.widget.*;
import android.content.Intent;
import static org.junit.Assert.*;
import static org.robolectric.Shadows.shadowOf;
@RunWith(RobolectricTestRunner.class) @Config(sdk=35,qualifiers="w390dp-h844dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
public class NativePagesTest {
    @Test public void nativeFileListHasSingleReceiveActionAndPreservesWorkbenchOnReturn()throws Exception{
        try(var c=Robolectric.buildActivity(FilesActivity.class).create().start()){
            FilesActivity app=c.get();app.render(new JSONArray().put(new JSONObject().put("id","fixture").put("name","PocketDesk-0.3.0.apk").put("size",2400000)));
            View root=app.getWindow().getDecorView();Button receive=find(root,"接收并下载");assertNotNull(receive);assertTrue(receive.getMinHeight()>=48);
            assertNull(root.findViewWithTag("native-navigation"));
            find(root,"‹").performClick();Intent intent=shadowOf(app).getNextStartedActivity();assertEquals(MainActivity.class.getName(),intent.getComponent().getClassName());
            assertTrue((intent.getFlags()&Intent.FLAG_ACTIVITY_CLEAR_TOP)!=0);assertTrue((intent.getFlags()&Intent.FLAG_ACTIVITY_SINGLE_TOP)!=0);
            snapshot(app,"/tmp/pd-native-files.png");
        }
    }
    @Test public void nativeFilePageTeachesEmptyState()throws Exception{
        try(var c=Robolectric.buildActivity(FilesActivity.class).create().start()){c.get().render(new JSONArray());assertNotNull(find(c.get().getWindow().getDecorView(),"查看手机已下载文件"));}
    }
    @Test public void nativeClientCannotForwardAuthorizationToAnotherOrigin()throws Exception{
        WorkspaceClient client=new WorkspaceClient(WorkspaceExperienceTest.URL);
        assertTrue(client.address("/api/v1/phone-files").startsWith("http://192.168.1.2:46387/"));
        try{client.address("https://evil.example/");fail();}catch(Exception expected){}
        try{client.address("//evil.example/api/");fail();}catch(Exception expected){}
    }
    @Test public void nativeDevicePageOffersConcreteActions()throws Exception{
        try(var c=Robolectric.buildActivity(ConnectionActivity.class).create().start()){
            View root=c.get().getWindow().getDecorView();assertNotNull(find(root,"扫描其他电脑"));assertNotNull(find(root,"打开快捷解锁"));snapshot(c.get(),"/tmp/pd-native-device.png");
        }
    }
    private Button find(View v,String label){if(v instanceof Button&&((Button)v).getText().toString().equals(label))return (Button)v;if(v instanceof ViewGroup)for(int i=0;i<((ViewGroup)v).getChildCount();i++){Button b=find(((ViewGroup)v).getChildAt(i),label);if(b!=null)return b;}return null;}
    private void snapshot(android.app.Activity app,String path)throws Exception{
        View root=app.findViewById(android.R.id.content);root.measure(View.MeasureSpec.makeMeasureSpec(390,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(844,View.MeasureSpec.EXACTLY));root.layout(0,0,390,844);
        android.graphics.Bitmap b=android.graphics.Bitmap.createBitmap(390,844,android.graphics.Bitmap.Config.ARGB_8888);root.draw(new android.graphics.Canvas(b));try(var out=new java.io.FileOutputStream(path)){b.compress(android.graphics.Bitmap.CompressFormat.PNG,100,out);}
    }
}
