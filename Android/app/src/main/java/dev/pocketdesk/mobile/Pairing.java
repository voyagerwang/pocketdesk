/**
 * [INPUT]: 电脑前扫码取得的邀请与应用私有保存的配对资料。
 * [OUTPUT]: 严格限制局域网 HTTPS 地址、证书指纹、协议版本及签名消息编码。
 * [POS]: 两端协议模型；不包含电脑密码，不从网络响应替换信任根。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;

import org.json.JSONObject;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;

final class Pairing {
    static String encode(byte[] value) { return Base64.getUrlEncoder().withoutPadding().encodeToString(value); }
    static byte[] decode(String value) { return Base64.getUrlDecoder().decode(value); }
    static byte[] message(String action, String request, String challenge, String credential) {
        for (String part : new String[]{action, request, challenge, credential})
            if (part.contains("\n") || part.contains("\r")) throw new IllegalArgumentException("配对数据无效");
        return ("PocketDesk-Native-v1\n" + action + "\n" + request + "\n" + challenge + "\n" + credential)
            .getBytes(StandardCharsets.UTF_8);
    }
    static JSONObject invitation(String text) throws Exception {
        if (!text.startsWith("pocketdesk://pair#") || text.length() > 4096) throw new Exception("请扫描电脑端的 App 配对二维码");
        JSONObject data = new JSONObject(new String(decode(text.substring(18)), StandardCharsets.UTF_8));
        if (data.getInt("v") != 1) throw new Exception("请更新 PocketDesk 后重新配对");
        endpoint(data.getString("endpoint"));
        for (String key : new String[]{"pin", "pairId", "challenge"})
            if (decode(data.getString(key)).length != 32) throw new Exception("配对数据无效");
        byte[] key = decode(data.getString("deviceKey"));
        if (key.length != 65 || key[0] != 4) throw new Exception("电脑身份无效");
        return data;
    }
    static URI endpoint(String text) throws Exception {
        URI uri = new URI(text);
        if (!"https".equals(uri.getScheme()) || uri.getUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null
            || (uri.getPath() != null && !uri.getPath().isEmpty()) || uri.getPort() < 1 || uri.getPort() > 65535)
            throw new Exception("请填写局域网 HTTPS 地址和端口");
        String host = uri.getHost();
        if (host == null || !host.matches("[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+")) throw new Exception("仅支持局域网 IPv4 地址");
        String[] parts = host.split("\\."); int[] n = new int[4];
        for (int i = 0; i < 4; i++) { n[i] = Integer.parseInt(parts[i]); if (n[i] > 255 || !parts[i].equals(Integer.toString(n[i]))) throw new Exception("地址无效"); }
        if (!(n[0] == 10 || (n[0] == 192 && n[1] == 168) || (n[0] == 172 && n[1] >= 16 && n[1] <= 31)))
            throw new Exception("首版仅支持同一局域网");
        return uri;
    }
    static String code(JSONObject offer, byte[] phoneKey) throws Exception {
        java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
        bytes.write("PocketDesk-QuickUnlock-Pair-v1".getBytes(StandardCharsets.UTF_8));
        bytes.write(decode(offer.getString("deviceKey"))); bytes.write(phoneKey); bytes.write(decode(offer.getString("challenge")));
        byte[] hash = MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray());
        long n = 0; for (int i = 0; i < 4; i++) n = (n << 8) | (hash[i] & 255);
        return String.format(java.util.Locale.ROOT, "%07d", n % 10000000);
    }
}
