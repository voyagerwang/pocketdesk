/**
 * [INPUT]: 真实 JDK TLS 测试服务与临时自签身份，复用生产 LocalClient。
 * [OUTPUT]: 固定指纹允许自签身份、错误指纹拒绝、重定向不跟随的网络回归。
 * [POS]: 不模拟 TLS 成功，不接触真实电脑解锁服务；测试结束销毁临时身份和监听。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import org.json.JSONObject;
import org.junit.Test;
import javax.net.ssl.*;
import java.nio.file.*;
import java.net.*;
import java.security.*;
import java.util.*;
import static org.junit.Assert.*;

public class LocalClientTest {
    @Test public void unlockFailurePreservesReasonAndRecovery()throws Exception{
        String message=LocalClient.failureMessage(new JSONObject().put("error","prepare-rejected").put("detail","系统密码输入尚不可用，本次未输入。"));
        assertTrue(message.contains("系统密码输入尚不可用"));assertTrue(message.contains("prepare-rejected"));
        assertTrue(LocalClient.failureMessage(new JSONObject().put("error","keychain-unavailable")).contains("检查并授权钥匙串"));
    }
    @Test public void pinnedTlsAndRedirectBoundary() throws Exception {
        String host = "127.0.0.1";
        Path dir = Files.createTempDirectory("pd-tls-test");
        Path identity = dir.resolve("identity.p12");
        SSLServerSocket server = null;
        try {
            Process generation = new ProcessBuilder(System.getProperty("java.home") + "/bin/keytool", "-genkeypair",
                "-alias", "test", "-keyalg", "RSA", "-keysize", "2048", "-validity", "1", "-dname", "CN=Local test",
                "-storetype", "PKCS12", "-keystore", identity.toString(), "-storepass", "test-only-pass", "-noprompt")
                .redirectErrorStream(true).redirectOutput(dir.resolve("keytool.log").toFile()).start();
            assertEquals(0, generation.waitFor());
            KeyStore store = KeyStore.getInstance("PKCS12");
            try (java.io.InputStream in = Files.newInputStream(identity)) { store.load(in, "test-only-pass".toCharArray()); }
            KeyManagerFactory keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()); keys.init(store, "test-only-pass".toCharArray());
            SSLContext tls = SSLContext.getInstance("TLS"); tls.init(keys.getKeyManagers(), null, null);
            server = (SSLServerSocket) tls.getServerSocketFactory().createServerSocket(0, 8, InetAddress.getByName(host));
            final SSLServerSocket listener = server;
            java.util.concurrent.atomic.AtomicInteger unexpected = new java.util.concurrent.atomic.AtomicInteger();
            Thread worker = new Thread(() -> {
                while (!listener.isClosed()) {
                    try (SSLSocket socket = (SSLSocket) listener.accept()) {
                        socket.setSoTimeout(5000);
                        java.io.BufferedReader input = new java.io.BufferedReader(new java.io.InputStreamReader(socket.getInputStream()));
                        String first = input.readLine(), line; int length = 0;
                        while ((line = input.readLine()) != null && !line.isEmpty())
                            if (line.toLowerCase(java.util.Locale.ROOT).startsWith("content-length:")) length = Integer.parseInt(line.substring(15).trim());
                        for (int i = 0; i < length; i++) if (input.read() < 0) break;
                        String response;
                        if (first.contains("/redirect ")) response = "HTTP/1.1 302 Found\r\nLocation: /unexpected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                        else {
                            if (first.contains("/unexpected ")) unexpected.incrementAndGet();
                            String body = "{\"confirmed\":true,\"state\":\"locked\"}";
                            response = "HTTP/1.1 200 OK\r\nContent-Length: " + body.length() + "\r\nConnection: close\r\n\r\n" + body;
                        }
                        socket.getOutputStream().write(response.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                    } catch (Exception failure) { if (!listener.isClosed()) System.err.println("TLS test server: " + failure); }
                }
            });
            worker.setDaemon(true); worker.start();
            String pin = Pairing.encode(MessageDigest.getInstance("SHA-256").digest(store.getCertificate("test").getEncoded()));
            JSONObject device = new JSONObject().put("endpoint", "https://" + host + ":" + server.getLocalPort()).put("pin", pin);
            assertEquals("locked", LocalClient.exchange(new URI(device.getString("endpoint")), Pairing.decode(device.getString("pin")), "status", new JSONObject()).getString("state"));
            assertThrows(Exception.class, () -> LocalClient.exchange(new URI(device.getString("endpoint")), Pairing.decode(device.getString("pin")), "redirect", new JSONObject()));
            assertEquals(0, unexpected.get());
            device.put("pin", Pairing.encode(new byte[32]));
            assertThrows(SSLException.class, () -> LocalClient.exchange(new URI(device.getString("endpoint")), Pairing.decode(device.getString("pin")), "status", new JSONObject()));
        } finally {
            if (server != null) server.close();
            try (java.util.stream.Stream<Path> paths = Files.walk(dir)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }
}
