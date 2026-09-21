/**
 * [INPUT]: WorkspaceClient 收件接口与 NativeDownload 系统任务。
 * [OUTPUT]: 原生文件列表、一次点击接收并下载、系统下载状态与失败重试。
 * [POS]: App 的文件页，复用现有票据与授权，不通过网页模拟下载点击。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import android.app.DownloadManager;
import android.content.Intent;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.util.concurrent.*;
public final class FilesActivity extends NativePage {
    private final ExecutorService network=Executors.newSingleThreadExecutor();
    private TextView status;private LinearLayout list;private Button refresh;private WorkspaceClient client;private int generation;
    protected String pageTitle(){return "电脑发来的文件";}
    @Override public void onCreate(Bundle state){super.onCreate(state);
        text("接收后直接保存到手机“下载”文件夹。",16);
        status=text("正在读取…",15);status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        refresh=action("刷新文件",this::refresh);
        action("查看手机已下载文件",()->{try{startActivity(new Intent(DownloadManager.ACTION_VIEW_DOWNLOADS));}catch(RuntimeException e){status.setText("请在手机文件管理器的“下载”中查看。");}});
        list=new LinearLayout(this);list.setOrientation(LinearLayout.VERTICAL);content.addView(list);
    }
    @Override protected void onResume(){super.onResume();refresh();}
    private void refresh(){
        final int current=++generation;refresh.setEnabled(false);status.setVisibility(View.VISIBLE);status.setText("正在读取…");
        network.execute(()->{try{WorkspaceClient c=WorkspaceClient.load(this);JSONObject result=c.request("/api/v1/phone-files",false);
            runOnUiThread(()->{if(isDestroyed()||current!=generation)return;client=c;refresh.setEnabled(true);status.setText("");render(result.optJSONArray("files"));});
        }catch(Exception e){runOnUiThread(()->{if(isDestroyed()||current!=generation)return;refresh.setEnabled(true);status.setVisibility(View.VISIBLE);status.setText(readableError(e));});}});
    }
    void render(JSONArray files){
        status.setVisibility(View.GONE);
        list.removeAllViews();if(files==null||files.length()==0){TextView empty=new TextView(this);empty.setText("暂无待收文件\n在电脑控制台点“发送文件”，这里就会出现。");empty.setTextSize(17);empty.setPadding(0,dp(24),0,0);list.addView(empty);return;}
        for(int i=0;i<files.length();i++){
            JSONObject file=files.optJSONObject(i);if(file==null)continue;
            String id=file.optString("id"),name=file.optString("name","文件");
            LinearLayout row=new LinearLayout(this);row.setOrientation(LinearLayout.VERTICAL);row.setPadding(0,dp(20),0,dp(20));
            TextView title=new TextView(this);title.setText(name);title.setTextSize(18);title.setTextColor(INK);row.addView(title);
            TextView detail=new TextView(this);detail.setText(String.format(java.util.Locale.ROOT,"%.1f MB",file.optDouble("size")/1048576));detail.setTextSize(14);detail.setTextColor(MUTED);row.addView(detail);
            TextView result=new TextView(this);result.setTextSize(14);result.setTextColor(MUTED);row.addView(result);showDownload(id,result);
            Button receive=new Button(this);receive.setText("接收并下载");receive.setMinHeight(dp(48));receive.setTextColor(android.graphics.Color.WHITE);receive.setBackgroundTintList(android.content.res.ColorStateList.valueOf(BLUE));row.addView(receive);
            receive.setOnClickListener(v->{if(client==null)return;receive.setEnabled(false);result.setText("正在准备下载…");WorkspaceClient snapshot=client;
                network.execute(()->{try{
                    JSONObject accepted=snapshot.request("/api/v1/phone-files/"+id+"/accept",true);String url=snapshot.address(accepted.getString("url"));
                    if(!new java.net.URI(url).getPath().startsWith("/api/v1/phone-files/download/"))throw new Exception("电脑返回了无效下载地址。");
                    runOnUiThread(()->{if(isDestroyed())return;try{
                        long download=NativeDownload.enqueue(this,snapshot.connection,url,name,"application/octet-stream");
                        getSharedPreferences("downloads",MODE_PRIVATE).edit().putLong(id,download).apply();result.setText("已交给系统下载，可在“已下载文件”中查看。");
                    }catch(Exception e){result.setText(readableError(e));}receive.setEnabled(true);});
                }catch(Exception e){runOnUiThread(()->{if(!isDestroyed()){result.setText(readableError(e));receive.setEnabled(true);}});}});
            });list.addView(row);
            View divider=new View(this);divider.setBackgroundColor(android.graphics.Color.rgb(218,225,235));list.addView(divider,new LinearLayout.LayoutParams(-1,dp(1)));
        }
    }
    private void showDownload(String id,TextView result){
        long task=getSharedPreferences("downloads",MODE_PRIVATE).getLong(id,-1);if(task<0)return;
        try(android.database.Cursor cursor=((DownloadManager)getSystemService(DOWNLOAD_SERVICE)).query(new DownloadManager.Query().setFilterById(task))){
            if(cursor!=null&&cursor.moveToFirst()){int state=cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS));result.setText(state==DownloadManager.STATUS_SUCCESSFUL?"已保存到手机下载文件夹":state==DownloadManager.STATUS_FAILED?"上次下载失败，可重新接收。":"系统正在下载…");}
        }catch(RuntimeException ignored){result.setText("请在手机已下载文件中查看进度。");}
    }
    @Override protected void onDestroy(){generation++;network.shutdownNow();super.onDestroy();}
}
