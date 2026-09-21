/**
 * [INPUT]: 电脑控制台的局域网工作台二维码。
 * [OUTPUT]: 验证后的连接地址与同源判断，不接受外部站点或缺失授权的地址。
 * [POS]: 工作台入口和下载共用的地址边界，与快捷解锁凭据独立。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import java.net.URI;
public final class WorkspaceConnection {
    public final String url;
    private final URI origin;
    public WorkspaceConnection(String text) throws Exception {
        URI uri = new URI(text.trim()); String host = uri.getHost();
        if (!("http".equals(uri.getScheme()) || "https".equals(uri.getScheme())) || host == null ||
            uri.getUserInfo() != null || uri.getFragment() != null || !local(host) ||
            !(uri.getPath().isEmpty() || uri.getPath().equals("/")) ||
            uri.getRawQuery() == null || !uri.getRawQuery().matches("token=[A-Za-z0-9_-]{20,128}"))
            throw new Exception("请扫描电脑控制台“手机扫码连接”的二维码，或粘贴完整连接链接。");
        origin = uri; url = uri.toASCIIString();
    }
    private static boolean local(String host) {
        if(host.endsWith(".local")) return true;
        String[] parts=host.split("\\."); if(parts.length!=4) return false;
        try { int[] n=new int[4]; for(int i=0;i<4;i++){n[i]=Integer.parseInt(parts[i]);if(n[i]<0||n[i]>255)return false;}
            return n[0]==10 || n[0]==192&&n[1]==168 || n[0]==172&&n[1]>=16&&n[1]<=31 || n[0]==100&&n[1]>=64&&n[1]<=127;
        } catch(NumberFormatException e){return false;}
    }
    public boolean owns(String address) {
        try { URI other=new URI(address); return other.getUserInfo()==null && origin.getScheme().equals(other.getScheme()) &&
            origin.getHost().equals(other.getHost()) && origin.getPort()==other.getPort(); }
        catch(Exception e){return false;}
    }
}
