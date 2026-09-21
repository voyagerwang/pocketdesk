/**
 * [INPUT]: Android 系统导航、安全区与既有蓝色品牌。
 * [OUTPUT]: 低频页面共用的返回标题和滚动内容，跟随工作台主题，不提供底部Tab。
 * [POS]: 原生页面框架；返回工作台复用既有 Activity，保留网页草稿，不重新加载。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
public abstract class NativePage extends Activity {
    // 对齐 Web/style.css 与 app-extras.css 的经典蓝/米白令牌，页面只消费语义色。
    protected int INK, MUTED, BLUE, SURFACE;
    private void appearance(){
        boolean muji="muji".equals(getSharedPreferences("appearance",MODE_PRIVATE).getString("theme","classic"));
        INK=Color.parseColor(muji?"#1a1a1a":"#171c2c"); MUTED=Color.parseColor(muji?"#666666":"#4a5266");
        BLUE=Color.parseColor(muji?"#b74127":"#1f6bff"); SURFACE=Color.parseColor(muji?"#f5f3ee":"#eef1f7");
        getWindow().setStatusBarColor(SURFACE);getWindow().setNavigationBarColor(SURFACE);
    }
    protected LinearLayout content;
    protected abstract String pageTitle();
    @Override public void onCreate(Bundle state){
        super.onCreate(state);appearance();getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setBackgroundColor(SURFACE);
        root.setOnApplyWindowInsetsListener((v,insets)->{android.graphics.Insets b=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.ime());v.setPadding(b.left,b.top,b.right,b.bottom);return insets;});
        LinearLayout bar=new LinearLayout(this);bar.setGravity(Gravity.CENTER_VERTICAL);bar.setPadding(dp(8),0,dp(20),0);
        Button back=new Button(this);back.setText("‹");back.setTextSize(28);back.setContentDescription("返回工作台");back.setBackgroundTintList(android.content.res.ColorStateList.valueOf(Color.TRANSPARENT));back.setOnClickListener(v->navigate(this,0));bar.addView(back,new LinearLayout.LayoutParams(dp(48),dp(56)));
        TextView title=new TextView(this);title.setText(pageTitle());title.setTextSize(22);title.setTextColor(INK);title.setTypeface(null,android.graphics.Typeface.BOLD);bar.addView(title);root.addView(bar);
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);content=new LinearLayout(this);content.setOrientation(LinearLayout.VERTICAL);content.setPadding(dp(20),dp(16),dp(20),dp(20));scroll.addView(content);root.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        setContentView(root);
    }
    static void navigate(Activity activity,int tab){
        Class<?> target=tab==0?MainActivity.class:tab==1?FilesActivity.class:ConnectionActivity.class;
        Intent intent=new Intent(activity,target);
        intent.addFlags(tab==0?Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP:Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
        activity.startActivity(intent);
    }
    protected int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    protected TextView text(String value,int size){TextView t=new TextView(this);t.setText(value);t.setTextSize(size);t.setTextColor(INK);t.setPadding(0,0,0,dp(12));content.addView(t);return t;}
    protected Button action(String title,Runnable run){Button b=new Button(this);b.setText(title);b.setAllCaps(false);b.setBackgroundTintList(android.content.res.ColorStateList.valueOf(Color.WHITE));b.setMinHeight(dp(48));b.setTextColor(BLUE);b.setOnClickListener(v->run.run());content.addView(b,new LinearLayout.LayoutParams(-1,-2));return b;}
    protected String readableError(Exception e){if(e instanceof java.io.IOException)return "连接中断。确认电脑正在运行且连接同一 Wi-Fi，然后重试。";return e.getMessage()==null?"操作未完成，请重试。":e.getMessage();}
}
