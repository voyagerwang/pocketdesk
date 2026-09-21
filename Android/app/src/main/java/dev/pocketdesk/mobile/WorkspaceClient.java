/**
 * [INPUT]: 本机保存的工作台连接与同源 HTTP API。
 * [OUTPUT]: 原生文件/设备页面共用的有界 JSON 请求，拒绝跳转和跨源授权转发。
 * [POS]: 原生页面的网络边界；不持有电脑密码，不改变系统证书信任。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import android.content.Context;
import android.net.Uri;
import org.json.JSONObject;
import java.net.*;
import java.io.*;
public final class WorkspaceClient {
    final WorkspaceConnection connection;
    private final String token;
    WorkspaceClient(String url)throws Exception{connection=new WorkspaceConnection(url);token=Uri.parse(url).getQueryParameter("token");}
    static WorkspaceClient load(Context context)throws Exception{
        String url=context.getSharedPreferences("workspace",Context.MODE_PRIVATE).getString("url",null);
        if(url==null)throw new Exception("请先在工作台连接电脑。");return new WorkspaceClient(url);
    }
    String host(){return Uri.parse(connection.url).getHost();}
    String address(String path)throws Exception{
        String url=new URI(connection.url).resolve(path).toASCIIString();
        if(!connection.owns(url))throw new Exception("连接地址不属于当前电脑。");return url;
    }
    JSONObject request(String path,boolean post)throws Exception{
        HttpURLConnection c=(HttpURLConnection)new URL(address(path)).openConnection();
        c.setInstanceFollowRedirects(false);c.setConnectTimeout(5000);c.setReadTimeout(10000);
        c.setRequestProperty("Authorization","Bearer "+token);
        try{
            if(post){c.setRequestMethod("POST");c.setRequestProperty("Content-Type","application/json");c.setDoOutput(true);try(OutputStream out=c.getOutputStream()){out.write("{}".getBytes(java.nio.charset.StandardCharsets.UTF_8));}}
            int code=c.getResponseCode();if(code==401)throw new Exception("连接授权已失效，请在设备页重新扫码。");
            if(code!=200)throw new Exception("电脑暂时无法完成操作（"+code+"），请重试。");
            try(InputStream in=c.getInputStream();ByteArrayOutputStream out=new ByteArrayOutputStream()){
                byte[] buffer=new byte[4096];int count;while((count=in.read(buffer))!=-1){if(out.size()+count>1048576)throw new Exception("电脑响应过大。");out.write(buffer,0,count);}
                return new JSONObject(out.toString("UTF-8"));
            }
        }finally{c.disconnect();}
    }
}
