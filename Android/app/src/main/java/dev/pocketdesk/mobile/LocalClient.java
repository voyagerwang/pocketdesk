/**
 * [INPUT]: 扫码固定的电脑叶证书 SHA256 与局域网地址。
 * [OUTPUT]: 仅向固定身份的电脑发送有界 HTTPS 请求；不重试、不跟随重定向。
 * [POS]: 唯一网络边界；自签身份仅在本连接验证，不修改系统信任、不接收任意证书。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;

import org.json.JSONObject;
import javax.net.ssl.*;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.security.cert.CertificateException;
import java.nio.charset.StandardCharsets;
import java.io.*;

final class LocalClient {
    static JSONObject post(JSONObject device, String action, JSONObject body) throws Exception {
        return exchange(Pairing.endpoint(device.getString("endpoint")), Pairing.decode(device.getString("pin")), action, body);
    }
    // 地址策略由唯一产品入口 post 校验；传输单独接受 URI，便于在回环网络验证真实 TLS。
    static JSONObject exchange(java.net.URI target, byte[] pin, String action, JSONObject body) throws Exception {
        String endpoint = target.toString();
        X509TrustManager trust = new X509TrustManager() {
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            public void checkClientTrusted(X509Certificate[] c, String a) throws CertificateException { throw new CertificateException(); }
            public void checkServerTrusted(X509Certificate[] c, String a) throws CertificateException {
                try {
                    if (c == null || c.length == 0) throw new CertificateException();
                    c[0].checkValidity();
                    if (!MessageDigest.isEqual(pin, MessageDigest.getInstance("SHA-256").digest(c[0].getEncoded())))
                        throw new CertificateException("电脑身份已变化，请在电脑前重新配对");
                } catch (Exception e) { throw new CertificateException("电脑身份验证失败", e); }
            }
        };
        SSLContext tls = SSLContext.getInstance("TLS"); tls.init(null, new TrustManager[]{trust}, null);
        HttpsURLConnection connection = (HttpsURLConnection) new java.net.URL(endpoint + "/api/native-unlock/" + action).openConnection(java.net.Proxy.NO_PROXY);
        connection.setSSLSocketFactory(tls.getSocketFactory());
        // 身份由带外固定的证书确定，IP 可变；再次比较叶证书而非无条件跳过主机验证。
        connection.setHostnameVerifier((host, session) -> {
            try { return host.equals(target.getHost()) && MessageDigest.isEqual(pin,
                MessageDigest.getInstance("SHA-256").digest(session.getPeerCertificates()[0].getEncoded())); }
            catch (Exception e) { return false; }
        });
        connection.setConnectTimeout(5000); connection.setReadTimeout(20000);
        connection.setInstanceFollowRedirects(false); connection.setRequestMethod("POST");
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("Connection", "close"); connection.setDoOutput(true);
        try {
            byte[] data = body.toString().getBytes(StandardCharsets.UTF_8);
            connection.setFixedLengthStreamingMode(data.length);
            try (OutputStream out = connection.getOutputStream()) { out.write(data); }
            if (connection.getResponseCode() != 200) throw new IOException("电脑拒绝连接，请检查版本和配对");
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (InputStream in = connection.getInputStream()) {
                byte[] buffer = new byte[2048]; int n;
                while ((n = in.read(buffer)) != -1) { if (out.size() + n > 16384) throw new IOException("响应过大"); out.write(buffer, 0, n); }
            }
            JSONObject response = new JSONObject(out.toString("UTF-8"));
            if (response.has("error")) {
                throw new IOException(failureMessage(response));
            }
            return response;
        } finally { connection.disconnect(); }
    }
    static String failureMessage(JSONObject response) {
        String code=response.optString("error","unknown"),detail=response.optString("detail","");
        return (detail.isEmpty()?explain(code):detail)+"\n错误码："+code;
    }
    static String explain(String code) {
        switch (code) {
            case "disabled": return "电脑尚未开启快捷解锁";
            case "keychain-unavailable": return "电脑钥匙串尚未授权。请在电脑控制台点击“检查并授权钥匙串”，完成后重试。";
            case "prepare-rejected": return "电脑锁屏密码输入尚不可用。请检查电脑锁屏界面与辅助功能授权。";
            case "submit-failed": return "密码输入被中止；请检查电脑状态，不会重复输入。";
            case "no-password": return "请在电脑端保存登录密码";
            case "unauthorized": return "配对不存在或已撤销，请重新配对";
            case "not-confirmed": return "请先在电脑端核对并确认配对";
            case "not-locked": return "电脑当前没有锁屏";
            case "unknown-state": return "暂时无法确认电脑锁屏状态，未执行解锁";
            case "pairing-session-invalid": return "邀请已失效或已使用，请在电脑端重新发起配对";
            case "rate-limited": return "请求过于频繁，请一分钟后重试";
            case "no-challenge": case "verification-failed": return "本次授权已失效，请重新点击解锁";
            default: return "本次操作未完成（" + code + "），不会自动重试";
        }
    }
}
