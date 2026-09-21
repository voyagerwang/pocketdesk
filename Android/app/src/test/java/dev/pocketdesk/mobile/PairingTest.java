/**
 * [INPUT]: Pairing 纯协议模型；Swift 独立产生的核对码固定向量。
 * [OUTPUT]: 地址/载荷拒绝矩阵与跨语言协议编码回归。
 * [POS]: 安卓 JVM 单测，不模拟系统生物识别成功。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import org.junit.Test;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import static org.junit.Assert.*;

public class PairingTest {
    @Test public void acceptsOnlyPrivateIpv4Https() throws Exception {
        for (String host : new String[]{"192.168.1.3", "10.0.0.2", "172.16.2.3", "172.31.255.2"})
            assertEquals(host, Pairing.endpoint("https://" + host + ":46487").getHost());
        for (String endpoint : new String[]{"http://192.168.1.3:46487", "https://127.0.0.1:46487", "https://8.8.8.8:443",
            "https://192.168.1.3.evil:443", "https://192.168.1.3:443/path", "https://a@192.168.1.3:443",
            "https://192.168.1.3:443#x", "https://192.168.1.3:443?x=y", "https://192.168.1.3", "https://192.168.1.999:443",
            "https://172.32.0.1:443", "https://192.168.01.3:443", "https://192.168.1.3:65536"}) {
            assertThrows(endpoint, Exception.class, () -> Pairing.endpoint(endpoint));
        }
    }
    @Test public void swiftPairingCodeVector() throws Exception {
        byte[] point = new byte[65]; Arrays.fill(point, (byte)1); point[0] = 4;
        byte[] challenge = new byte[32]; Arrays.fill(challenge, (byte)2);
        JSONObject offer = new JSONObject().put("deviceKey", Pairing.encode(point)).put("challenge", Pairing.encode(challenge));
        assertEquals("4341120", Pairing.code(offer, point));
    }
    @Test public void canonicalMessageAndDomainSeparation() {
        assertEquals("PocketDesk-Native-v1\nunlock\nrequest\nchallenge\ncredential",
            new String(Pairing.message("unlock", "request", "challenge", "credential"), StandardCharsets.UTF_8));
        assertFalse(Arrays.equals(Pairing.message("pair", "r", "c", "k"), Pairing.message("unlock", "r", "c", "k")));
        assertThrows(IllegalArgumentException.class, () -> Pairing.message("unlock", "r\nx", "c", "k"));
    }
    @Test public void invitationVersionAndShape() throws Exception {
        byte[] point = new byte[65]; point[0] = 4;
        JSONObject data = new JSONObject().put("v",1).put("endpoint","https://192.168.1.2:46487")
            .put("pin", Pairing.encode(new byte[32])).put("pairId", Pairing.encode(new byte[32]))
            .put("challenge", Pairing.encode(new byte[32])).put("deviceKey", Pairing.encode(point));
        String invite = "pocketdesk://pair#" + Pairing.encode(data.toString().getBytes(StandardCharsets.UTF_8));
        assertEquals(1, Pairing.invitation(invite).getInt("v"));
        data.put("v",2);
        assertThrows(Exception.class, () -> Pairing.invitation("pocketdesk://pair#" + Pairing.encode(data.toString().getBytes(StandardCharsets.UTF_8))));
        assertThrows(Exception.class, () -> Pairing.invitation("https://example.com"));
    }
}
