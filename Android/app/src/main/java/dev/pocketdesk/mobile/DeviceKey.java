/**
 * [INPUT]: AndroidKeyStore 与系统 BiometricPrompt 每次操作授权。
 * [OUTPUT]: 不可导出的 P256 私钥及待系统授权的签名对象。
 * [POS]: 手机身份根；不保存电脑密码，取消验证不签名，不提供软件密钥降级。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.security.*;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;

final class DeviceKey {
    static String create() throws Exception {
        String alias = "pocketdesk-" + java.util.UUID.randomUUID();
        KeyPairGenerator generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore");
        generator.initialize(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256).setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG | KeyProperties.AUTH_DEVICE_CREDENTIAL)
            .build());
        generator.generateKeyPair(); return alias;
    }
    static KeyStore store() throws Exception { KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null); return store; }
    static Signature signer(String alias) throws Exception {
        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign((PrivateKey) store().getKey(alias, null)); return signer;
    }
    static byte[] point(String alias) throws Exception {
        ECPublicKey key = (ECPublicKey) store().getCertificate(alias).getPublicKey();
        byte[] point = new byte[65]; point[0] = 4;
        for (int i = 0; i < 2; i++) {
            byte[] coordinate = (i == 0 ? key.getW().getAffineX() : key.getW().getAffineY()).toByteArray();
            int n = Math.min(32, coordinate.length);
            System.arraycopy(coordinate, coordinate.length - n, point, 1 + i * 32 + 32 - n, n);
        }
        return point;
    }
    static void delete(String alias) { try { store().deleteEntry(alias); } catch (Exception ignored) {} }
}
