/**
 * [INPUT]: 已核验同源的下载票据与系统 DownloadManager。
 * [OUTPUT]: 原生下载任务；文件名沿用工作台附件编码，明确区分排队与完成。
 * [POS]: WebView 和原生文件页共用的下载适配器，不转发长期授权 token。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import android.app.DownloadManager;
import android.content.Context;
import android.net.Uri;
import android.os.Environment;
final class NativeDownload {
    static long enqueue(Context context,WorkspaceConnection connection,String url,String name,String mime)throws Exception{
        if(!connection.owns(url))throw new Exception("下载地址不属于当前电脑。");
        String clean=name.replaceAll("[/\\\\\\r\\n]","_");if(clean.isEmpty()||clean.equals(".")||clean.equals(".."))clean="PocketDesk-file";
        DownloadManager.Request request=new DownloadManager.Request(Uri.parse(url));
        request.setTitle(clean).setMimeType(mime).setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS,clean);
        return ((DownloadManager)context.getSystemService(Context.DOWNLOAD_SERVICE)).enqueue(request);
    }
}
