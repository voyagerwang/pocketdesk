/**
 * [INPUT]: 本地工作台连接、只读电脑状态及既有原生解锁页面。
 * [OUTPUT]: 原生设备页，真实可达状态、重连/扫码/快捷解锁入口与返回工作台。
 * [POS]: 设备管理从网页菜单下沉到原生页面，不清除草稿、不自动执行解锁。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import android.content.Intent;
import android.os.Bundle;
import android.widget.TextView;
import java.util.concurrent.*;
public final class ConnectionActivity extends NativePage {
    private final ExecutorService network=Executors.newSingleThreadExecutor();private TextView state;private android.widget.Button check;
    protected String pageTitle(){return "我的电脑";}
    @Override public void onCreate(Bundle saved){super.onCreate(saved);
        String host="尚未连接电脑";try{host=WorkspaceClient.load(this).host();}catch(Exception ignored){}
        text(host,24);state=text("正在检查连接…",16);
        check=action("检查连接",this::check);action("重新连接工作台",()->workspaceAction("reconnect"));
        action("扫描其他电脑",()->workspaceAction("scan"));action("粘贴连接链接",()->workspaceAction("paste"));
        text("快捷解锁",20);text("验证手机身份后解锁 Mac。首次使用请在电脑控制台配置。",16);
        action("打开快捷解锁",()->startActivity(new Intent(this,UnlockActivity.class)));
    }
    @Override protected void onResume(){super.onResume();check();}
    private void check(){if(!check.isEnabled())return;check.setEnabled(false);state.setText("正在检查连接…");network.execute(()->{try{WorkspaceClient.load(this).request("/api/status",false);runOnUiThread(()->{if(!isDestroyed()){check.setEnabled(true);state.setText("电脑服务可用");}});}catch(Exception e){runOnUiThread(()->{if(!isDestroyed()){check.setEnabled(true);state.setText(readableError(e));}});}});}
    private void workspaceAction(String action){startActivity(new Intent(this,MainActivity.class).putExtra("workspaceAction",action).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP|Intent.FLAG_ACTIVITY_SINGLE_TOP));}
    @Override protected void onDestroy(){network.shutdownNow();super.onDestroy();}
}
