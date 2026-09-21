/**
 * [INPUT]: 电脑工作台连接码、WebView、系统文件选择与下载服务。
 * [OUTPUT]: 首页锁屏直达解锁、设置中打开低频文件和设备页，返回保留网页实例与草稿；默认完整网页工作台，连接后隐藏原生顶栏；受限原生传感器桥接支持 HTTP 工作台甩送；网页设置通过受限用户导航打开连接管理，状态为空不占布局。
 * [POS]: 安卓前台入口，复用 Mac 提供的工作台，不复制网页业务与输入状态。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.webkit.*;
import android.widget.*;
import com.google.zxing.integration.android.*;

public final class MainActivity extends Activity {
    private WebView web;
    private TextView message;
    private LinearLayout welcome, appBar;
    private ScrollView onboarding;
    private boolean loadFailed;
    private WorkspaceConnection connection;
    private NativeMotionBridge motionBridge;
    private ValueCallback<Uri[]> fileCallback;
    private static final int CAMERA=41, FILES=42;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state); getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setBackgroundColor(Color.rgb(238,241,247));
        root.setOnApplyWindowInsetsListener((v,insets)->{android.graphics.Insets b=insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());v.setPadding(b.left,b.top,b.right,b.bottom);return insets;});
        appBar=new LinearLayout(this);LinearLayout bar=appBar;bar.setGravity(Gravity.CENTER_VERTICAL);bar.setPadding(dp(20),0,dp(12),0);
        TextView title=new TextView(this);title.setText("PocketDesk");title.setTextSize(20);title.setTextColor(Color.rgb(23,28,44));title.setGravity(Gravity.CENTER_VERTICAL);title.setTypeface(null,android.graphics.Typeface.BOLD);bar.addView(title,new LinearLayout.LayoutParams(0,dp(52),1));
        Button menu=new Button(this);menu.setText("更多");menu.setTextSize(14);menu.setContentDescription("连接设置");menu.setTextColor(Color.rgb(31,107,255));menu.setBackgroundTintList(android.content.res.ColorStateList.valueOf(Color.TRANSPARENT));menu.setMinimumWidth(0);menu.setMinWidth(0);menu.setOnClickListener(v->settings());bar.addView(menu,new LinearLayout.LayoutParams(dp(64),dp(48)));root.addView(bar);
        welcome=new LinearLayout(this);welcome.setOrientation(LinearLayout.VERTICAL);welcome.setPadding(dp(24),dp(16),dp(24),dp(16));
        label(welcome,"连接电脑",24);
        label(welcome,"连接后即可输入文字、操作电脑和收发文件。",16);
        label(welcome,"首次使用：手机与电脑连接同一 Wi-Fi，在电脑 PocketDesk 控制台找到“手机扫码连接”的二维码。",16);
        button(welcome,"扫描电脑上的连接码",this::scan);button(welcome,"粘贴连接链接",this::paste);onboarding=new ScrollView(this);onboarding.addView(welcome);root.addView(onboarding,new LinearLayout.LayoutParams(-1,0,1));
        message=new TextView(this);message.setTextSize(15);message.setPadding(dp(16),dp(8),dp(16),dp(8));message.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);message.setVisibility(View.GONE);root.addView(message);
        web=new WebView(this);web.setVisibility(View.GONE);root.addView(web,new LinearLayout.LayoutParams(-1,0,1));setContentView(root);
        WebSettings options=web.getSettings();options.setUserAgentString(options.getUserAgentString()+" PocketDeskAndroid/0.4.1");options.setJavaScriptEnabled(true);options.setDomStorageEnabled(true);
        options.setAllowFileAccess(false);options.setAllowContentAccess(true);options.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        motionBridge=new NativeMotionBridge(this,web);
        web.addJavascriptInterface(motionBridge,NativeMotionBridge.NAME);
        web.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView v,WebResourceRequest request){
                String url=request.getUrl().toString();
                if(request.isForMainFrame() && request.hasGesture() && connection!=null && connection.owns(v.getUrl()) && "pocketdesk".equals(request.getUrl().getScheme())) {
                    String route=request.getUrl().getHost();
                    if("settings".equals(route)||"files".equals(route)||"unlock".equals(route)){
                        String theme=request.getUrl().getQueryParameter("theme");
                        getSharedPreferences("appearance",MODE_PRIVATE).edit().putString("theme","muji".equals(theme)?"muji":"classic").apply();
                        if("settings".equals(route))settings();
                        else if("files".equals(route))NativePage.navigate(MainActivity.this,1);
                        else startActivity(new Intent(MainActivity.this,UnlockActivity.class).putExtra("quickUnlock",!"settings".equals(request.getUrl().getQueryParameter("mode"))));
                    }
                    return true;
                }
                return connection==null || !connection.owns(url);
            }
            @Override public void onPageStarted(WebView v,String url,android.graphics.Bitmap icon){loadFailed=false;motionBridge.stopOnUiThread();}
            @Override public void onPageFinished(WebView v,String url){if(!loadFailed&&connection!=null&&connection.owns(url))showMessage("");}
            @Override public void onReceivedError(WebView v,WebResourceRequest request,WebResourceError error){if(request.isForMainFrame()){loadFailed=true;appBar.setVisibility(View.VISIBLE);showMessage("连接中断。确认电脑 PocketDesk 正在运行且连接同一 Wi-Fi，可在连接设置中重试或重新扫码。");}}
            @Override public void onReceivedSslError(WebView v,android.webkit.SslErrorHandler handler,android.net.http.SslError error){handler.cancel();loadFailed=true;appBar.setVisibility(View.VISIBLE);showMessage("此 HTTPS 证书尚未受信任。请重新扫描电脑上的“手机连接 · App / 浏览器”二维码。");}
        });
        web.setWebChromeClient(new WebChromeClient(){
            @Override public boolean onShowFileChooser(WebView v,ValueCallback<Uri[]> callback,FileChooserParams params){
                if(fileCallback!=null)fileCallback.onReceiveValue(null);fileCallback=callback;
                try {startActivityForResult(params.createIntent(),FILES);}catch(RuntimeException e){fileCallback.onReceiveValue(null);fileCallback=null;showMessage("无法打开文件选择器，请检查手机文件应用。");}return true;
            }
        });
        web.setDownloadListener((url,agent,disposition,mime,length)->download(url,disposition,mime));
        String saved=getSharedPreferences("workspace",MODE_PRIVATE).getString("url",null);
        if(saved!=null)connect(saved);
        handleWorkspaceAction(getIntent());
    }
    void connect(String text){
        if(text!=null&&text.startsWith("pocketdesk://pair#")){startActivity(new Intent(this,UnlockActivity.class).putExtra("invitation",text));return;}
        try {WorkspaceConnection next=new WorkspaceConnection(text);connection=next;
            getSharedPreferences("workspace",MODE_PRIVATE).edit().putString("url",next.url).apply();
            appBar.setVisibility(View.GONE);onboarding.setVisibility(View.GONE);web.setVisibility(View.VISIBLE);showMessage("正在打开工作台…");web.loadUrl(next.url);
        }catch(Exception e){showMessage(e.getMessage()==null?"请粘贴电脑端完整连接链接。":e.getMessage());}
    }
    boolean ownsWorkspacePage(String url){return connection!=null&&url!=null&&connection.owns(url);}
    private void showMessage(String text){message.setText(text);message.setVisibility(text==null||text.isEmpty()?View.GONE:View.VISIBLE);}
    private void download(String url,String disposition,String mime){
        if(connection==null)return;
        try {NativeDownload.enqueue(this,connection,url,downloadName(url,disposition,mime),mime);showMessage("已交给系统下载，可在文件页查看。");}
        catch(Exception e){showMessage(e.getMessage()==null?"无法启动下载，请重试。":e.getMessage());}
    }
    static String downloadName(String url,String disposition,String mime){
        String name=URLUtil.guessFileName(url,disposition,mime);
        if(disposition!=null){java.util.regex.Matcher match=java.util.regex.Pattern.compile("filename\\*=UTF-8''([^;]+)",java.util.regex.Pattern.CASE_INSENSITIVE).matcher(disposition);
            if(match.find())try{name=java.net.URLDecoder.decode(match.group(1).replace("+","%2B"),"UTF-8");}catch(Exception ignored){}
        }
        return name.replaceAll("[/\\\\\\r\\n]","_");
    }
    private void scan(){
        if(checkSelfPermission(android.Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{android.Manifest.permission.CAMERA},CAMERA);return;}
        try {new IntentIntegrator(this).setCaptureActivity(SquareCaptureActivity.class).setDesiredBarcodeFormats(IntentIntegrator.QR_CODE).setOrientationLocked(false).setBeepEnabled(false).setPrompt("").initiateScan();}
        catch(RuntimeException|LinkageError e){showMessage("无法打开相机，请在连接设置中粘贴连接链接。");}
    }
    @Override public void onRequestPermissionsResult(int code,String[] permissions,int[] grants){super.onRequestPermissionsResult(code,permissions,grants);if(code==CAMERA){if(grants.length>0&&grants[0]==PackageManager.PERMISSION_GRANTED)scan();else showMessage("相机权限未开启。可在手机设置中允许相机，或粘贴连接链接。");}}
    private void settings(){if(connection!=null){NativePage.navigate(this,2);return;}new AlertDialog.Builder(this).setTitle("连接设置").setItems(new String[]{"重新连接","扫描电脑连接码","粘贴连接链接","快捷解锁"},(d,n)->{if(n==0){if(connection!=null)connect(connection.url);else scan();}else if(n==1)scan();else if(n==2)paste();else startActivity(new Intent(this,UnlockActivity.class));}).setNegativeButton("关闭",null).show();}
    private void paste(){EditText field=new EditText(this);field.setHint("电脑二维码下方的完整链接");field.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI);new AlertDialog.Builder(this).setTitle("粘贴连接链接").setView(field).setPositiveButton("连接",(d,w)->connect(field.getText().toString().trim())).setNegativeButton("取消",null).show();}
    @Override protected void onActivityResult(int code,int result,Intent data){
        if(code==FILES){if(fileCallback!=null){fileCallback.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(result,data));fileCallback=null;}return;}
        IntentResult scanned=IntentIntegrator.parseActivityResult(code,result,data);if(scanned!=null){if(scanned.getContents()!=null)connect(scanned.getContents());else showMessage("已取消扫码，现有连接保留。");return;}super.onActivityResult(code,result,data);
    }
    @Override protected void onNewIntent(Intent intent){super.onNewIntent(intent);setIntent(intent);handleWorkspaceAction(intent);}
    private void handleWorkspaceAction(Intent intent){String action=intent.getStringExtra("workspaceAction");intent.removeExtra("workspaceAction");if("scan".equals(action))scan();else if("paste".equals(action))paste();else if("reconnect".equals(action)){if(connection!=null)connect(connection.url);else scan();}}
    @Override public void onBackPressed(){if(web.canGoBack())web.goBack();else super.onBackPressed();}
    @Override protected void onResume(){super.onResume();if(web!=null)web.evaluateJavascript("window.pocketdeskMotionResume&&window.pocketdeskMotionResume()",null);}
    @Override protected void onPause(){if(web!=null)web.evaluateJavascript("window.pocketdeskMotionSuspend&&window.pocketdeskMotionSuspend('native-paused')",null);if(motionBridge!=null)motionBridge.stopOnUiThread();super.onPause();}
    @Override protected void onDestroy(){if(fileCallback!=null)fileCallback.onReceiveValue(null);if(motionBridge!=null)motionBridge.stopOnUiThread();web.destroy();super.onDestroy();}
    private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    private void label(LinearLayout parent,String text,int size){TextView v=new TextView(this);v.setText(text);v.setTextSize(size);v.setTextColor(Color.rgb(23,28,44));v.setPadding(0,0,0,dp(20));parent.addView(v);}
    private void button(LinearLayout parent,String text,Runnable action){Button b=new Button(this);b.setText(text);if(text.startsWith("扫描")){b.setBackgroundTintList(android.content.res.ColorStateList.valueOf(Color.rgb(31,107,255)));b.setTextColor(Color.WHITE);}b.setMinHeight(dp(52));b.setOnClickListener(v->action.run());parent.addView(b,new LinearLayout.LayoutParams(-1,-2));}
}
