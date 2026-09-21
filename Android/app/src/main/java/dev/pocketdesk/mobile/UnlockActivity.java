/**
 * [INPUT]: 原生界面、ZXing 本机扫码、AndroidKeyStore 与 BiometricPrompt、LocalClient。
 * [OUTPUT]: 局域网配对、核对确认、状态刷新与用户逐次授权解锁；按未配对、待确认、已连接分阶段显示，扫码拒绝与失败可原地恢复。
 * [POS]: 工作台的可选快捷解锁页面；不后台常驻、不记录敏感载荷、不自动执行或重试解锁。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;

import android.app.*;
import android.content.*;
import android.graphics.Color;
import android.hardware.biometrics.*;
import android.os.*;
import android.view.*;
import android.widget.*;
import com.google.zxing.integration.android.IntentIntegrator;
import com.google.zxing.integration.android.IntentResult;
import org.json.JSONObject;
import java.security.Signature;
import java.util.concurrent.*;

public final class UnlockActivity extends NativePage {
    private final ExecutorService network = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private JSONObject device;
    private TextView status, name;
    private Button unlock, refresh, scan, help, manage;
    private TextView introduction;
    private static final int CAMERA_REQUEST = 41;
    private boolean busy;
    private boolean quickUnlock, returnOnSuccess;
    private int generation;
    private CancellationSignal authentication;
    private boolean authenticating;
    private String temporaryAlias;
    private android.content.SharedPreferences preferences;

    @Override protected String pageTitle() { return "快捷解锁"; }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        preferences = getSharedPreferences("pairing", MODE_PRIVATE);
        quickUnlock = getIntent().getBooleanExtra("quickUnlock",false); returnOnSuccess=quickUnlock;
        try { String saved = preferences.getString("device", null); if (saved != null) device = new JSONObject(saved); }
        catch (Exception ignored) { device = null; }
        LinearLayout column = content;
        name = label(column, "连接你的 Mac", 26);
        name.setTypeface(null, android.graphics.Typeface.BOLD);
        introduction = label(column, "手机和电脑连接同一 Wi-Fi。\n\n在电脑网页控制台的“快捷解锁”区域保存登录密码、开启功能，再点“添加解锁设备”。", 16);
        status = label(column, "准备好电脑上的二维码后，点击下方开始。", 16);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        scan = button(column, "扫码连接电脑", this::scan);
        primary(scan);
        unlock = button(column, "解锁电脑", this::unlock);
        primary(unlock);
        refresh = button(column, "刷新电脑状态", this::refresh);
        help = button(column, "找不到配对码 / 无法扫码", this::pairingHelp);
        manage = button(column, "连接设置", this::connectionSettings);
        label(column, "电脑密码只保存在 Mac。每次解锁由手机系统验证身份。", 14);
        render();
        String invitation = getIntent().getStringExtra("invitation");
        if (invitation != null) pair(invitation);
    }

    /* ---------- 配对引导与按需相机权限 ---------- */
    private void scan() {
        if (busy || device != null) return;
        if (!getPackageManager().hasSystemFeature(android.content.pm.PackageManager.FEATURE_CAMERA_ANY)) {
            status.setText("这台设备没有可用相机，请使用配对链接连接。"); pairingHelp(); return;
        }
        if (checkSelfPermission(android.Manifest.permission.CAMERA) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{android.Manifest.permission.CAMERA}, CAMERA_REQUEST); return;
        }
        try {
            new IntentIntegrator(this).setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
                .setPrompt("扫描电脑控制台“快捷解锁”中的配对码")
                .setCaptureActivity(SquareCaptureActivity.class).setBeepEnabled(false).setOrientationLocked(false).initiateScan();
        } catch (RuntimeException | LinkageError failure) {
            status.setText("扫码暂时无法打开。请重试，或点击下方帮助粘贴配对链接。");
        }
    }
    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(requestCode, permissions, grants);
        if (requestCode != CAMERA_REQUEST) return;
        if (grants.length > 0 && grants[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) { scan(); return; }
        status.setText("相机权限未开启，尚未开始配对。你可以开启权限后重试，也可以粘贴配对链接。");
        new AlertDialog.Builder(this).setTitle("允许相机后才能扫码")
            .setMessage("相机只用于读取电脑上的配对码，画面不会上传。也可以不使用相机，改用配对链接。")
            .setPositiveButton("打开权限设置", (d,w) -> {
                try { startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    android.net.Uri.parse("package:" + getPackageName()))); }
                catch (RuntimeException e) { status.setText("请在手机设置 → 应用 → PocketDesk → 权限中开启相机。"); }
            }).setNeutralButton("粘贴配对链接", (d,w) -> pasteInvitation())
            .setNegativeButton("暂不开启", null).show();
    }
    private void pairingHelp() {
        new AlertDialog.Builder(this).setTitle("在电脑上获取配对码")
            .setMessage("1. 打开电脑网页控制台的“快捷解锁”区域。\n2. 保存电脑登录密码、开启快捷解锁，点击“添加解锁设备”。\n3. 用手机扫描出现的二维码。\n\n无法扫码？在网页配对区域点击“复制配对链接”，将完整链接传到自己的手机，再粘贴。链接 5 分钟内有效，不是数字邀请码。\n\n电脑上没有“快捷解锁设置”？请先安装与此 App 配套的 Mac 版本。控制台原有的网页二维码不能用于快捷解锁。")
            .setPositiveButton("知道了", null).setNeutralButton("粘贴配对链接", (d,w) -> pasteInvitation()).show();
    }
    private void pasteInvitation() {
        input("粘贴配对链接", "粘贴电脑控制台“快捷解锁”中复制的完整链接", "", this::pair);
    }
    private void connectionSettings() {
        new AlertDialog.Builder(this).setTitle("连接设置")
            .setItems(new String[]{"更新电脑连接地址", "移除这台电脑", "关于快捷解锁与网页工作台"}, (d,which) -> {
                if (which == 0 && device != null) {
                    input("更新电脑地址", "从电脑配对窗口查看地址；电脑身份仍会核验", device.optString("endpoint"), text -> {
                        try { Pairing.endpoint(text); device.put("endpoint", text); save(); refresh(); }
                        catch (Exception e) { error(e); }
                    });
                } else if (which == 1) {
                    new AlertDialog.Builder(this).setTitle("移除这台电脑？")
                        .setMessage("移除后需重新扫码。电脑端的手机授权可在“快捷解锁设置”中撤销。")
                        .setPositiveButton("移除", (dialog,w) -> {
                            generation++;
                            if (device != null) DeviceKey.delete(device.optString("alias"));
                            device = null; preferences.edit().clear().apply(); render();
                            status.setText("已移除。可以重新扫码连接电脑。");
                        }).setNegativeButton("取消", null).show();
                } else {
                    new AlertDialog.Builder(this).setTitle("快捷解锁与网页工作台")
                        .setMessage("这里用于同一 Wi-Fi 下解锁 Mac。返回 App 首页即可使用工作台中的输入、触控板、画面和文件传输。\n\n工作台连接不需要开启快捷解锁。电脑需要保持唤醒；不支持重启后的首次登录。")
                        .setPositiveButton("知道了", null).show();
                }
            }).setNegativeButton("关闭", null).show();
    }

    protected int dp(int n) { return Math.round(n * getResources().getDisplayMetrics().density); }
    private TextView label(LinearLayout parent, String text, int size) {
        TextView view = new TextView(this); view.setText(text); view.setTextSize(size); view.setTextColor(INK);
        view.setPadding(0,dp(10),0,dp(10)); parent.addView(view); return view;
    }
    private Button button(LinearLayout parent, String text, Runnable action) {
        Button button = new Button(this); button.setText(text); button.setAllCaps(false); button.setMinHeight(dp(52));
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(-1,-2);
        layout.topMargin = dp(8);
        parent.addView(button, layout); button.setOnClickListener(v -> action.run()); return button;
    }
    private void primary(Button button) {
        int[][] states = new int[][]{new int[]{android.R.attr.state_enabled}, new int[]{}};
        button.setBackgroundTintList(new android.content.res.ColorStateList(states,
            new int[]{BLUE, SURFACE}));
        button.setTextColor(new android.content.res.ColorStateList(states,
            new int[]{Color.WHITE, MUTED}));
    }
    interface TextAction { void accept(String text); }
    private void input(String title, String hint, String value, TextAction action) {
        EditText field = new EditText(this); field.setHint(hint); field.setText(value); field.setSingleLine(false);
        field.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        new AlertDialog.Builder(this).setTitle(title).setView(field).setPositiveButton("继续", (d,w) -> action.accept(field.getText().toString().trim()))
            .setNegativeButton("取消", null).show();
    }
    private void render() {
        boolean paired = device != null;
        boolean confirmed = paired && device.optBoolean("confirmed", false);
        name.setText(!paired ? "连接你的 Mac" : confirmed ? device.optString("name", "我的 Mac") : "在电脑上确认连接");
        introduction.setVisibility(paired ? View.GONE : View.VISIBLE);
        scan.setVisibility(paired ? View.GONE : View.VISIBLE);
        help.setVisibility(paired ? View.GONE : View.VISIBLE);
        unlock.setVisibility(confirmed ? View.VISIBLE : View.GONE);
        refresh.setVisibility(paired ? View.VISIBLE : View.GONE);
        manage.setVisibility(paired ? View.VISIBLE : View.GONE);
        refresh.setText(confirmed ? "刷新电脑状态" : "我已在电脑上确认");
        unlock.setEnabled(false);
        refresh.setEnabled(paired && !busy); manage.setEnabled(paired && !busy);
        scan.setEnabled(!busy); help.setEnabled(!busy);
    }
    private void working(String text) { busy = true; render(); status.setText(text); }
    private void idle() { busy = false; render(); }
    private void save() throws Exception {
        if (!preferences.edit().putString("device", device.toString()).commit()) throw new Exception("配对资料保存失败，请重试");
    }
    private void error(Exception error) {
        quickUnlock=false;
        idle();
        clearTemporaryKey();
        String message = error.getMessage();
        if (error instanceof javax.net.ssl.SSLException) message = "电脑身份或证书验证失败，请在电脑前重新配对，不要安装证书。";
        else if (error instanceof java.net.SocketTimeoutException || error instanceof java.net.ConnectException)
            message = "连接超时：请确认同一局域网、电脑已唤醒、地址和防火墙允许连接。若刚提交解锁，请先检查电脑，不会自动重试。";
        status.setText(message == null ? "操作未完成，请检查连接或重新配对。" : message);
    }
    interface Work { JSONObject run() throws Exception; }
    interface Result { void accept(JSONObject result) throws Exception; }
    private void request(Work work, Result result) {
        int current = generation;
        network.execute(() -> {
            try { JSONObject response = work.run(); main.post(() -> {
                if (current != generation || isDestroyed()) return;
                try { result.accept(response); } catch (Exception e) { error(e); }
            }); } catch (Exception e) { main.post(() -> { if (current == generation && !isDestroyed()) error(e); }); }
        });
    }
    @Override protected void onActivityResult(int requestCode, int resultCode, Intent intent) {
        IntentResult scanned = IntentIntegrator.parseActivityResult(requestCode, resultCode, intent);
        if (scanned != null) {
            if (scanned.getContents() != null) pair(scanned.getContents());
            else status.setText("扫码未完成。可以重新扫码，或在帮助中粘贴配对链接。");
            return;
        }
        super.onActivityResult(requestCode, resultCode, intent);
    }
    private void pair(String text) {
        if (device != null) { status.setText("请先移除当前手机配对，再添加新电脑。电脑端原有登记需要单独撤销。"); return; }
        try {
            if (text == null || text.trim().isEmpty()) throw new Exception("请先粘贴电脑端复制的完整配对链接。");
            if (text.startsWith("http://") || text.startsWith("https://"))
                throw new Exception("这是网页连接码。请扫描电脑控制台“快捷解锁”→“添加解锁设备”中的配对码。");
            JSONObject offer = Pairing.invitation(text);
            KeyguardManager guard = (KeyguardManager) getSystemService(KEYGUARD_SERVICE);
            if (!guard.isDeviceSecure()) throw new Exception("请先在手机系统设置中开启锁屏密码");
            working("创建本机身份，请完成手机系统验证。");
            clearTemporaryKey();
            temporaryAlias = DeviceKey.create(); final String alias = temporaryAlias;
            byte[] publicKey = DeviceKey.point(alias);
            String expectedCode = Pairing.code(offer, publicKey);
            byte[] message = Pairing.message("pair", offer.getString("pairId"), offer.getString("challenge"), Pairing.encode(publicKey));
            authenticate(alias, message, signature -> {
                JSONObject body = new JSONObject().put("pairId", offer.getString("pairId"))
                    .put("publicKey", Pairing.encode(publicKey)).put("signature", Pairing.encode(signature)).put("label", Build.MANUFACTURER + " " + Build.MODEL);
                request(() -> LocalClient.post(offer, "register", body), response -> {
                    if (!expectedCode.equals(response.getString("code"))) throw new Exception("核对信息不一致，请在电脑端拒绝配对");
                    device = new JSONObject().put("endpoint", offer.getString("endpoint")).put("pin", offer.getString("pin"))
                        .put("name", offer.optString("name", "我的 Mac")).put("alias", alias)
                        .put("credentialId", response.getString("credentialId")).put("verificationCode", expectedCode).put("confirmed", false);
                    save(); temporaryAlias = null; idle();
                    status.setText(getString(R.string.pairing_code, expectedCode));
                });
            });
        } catch (Exception e) { error(e); }
    }
    private JSONObject authBody(JSONObject snapshot) throws Exception { return new JSONObject().put("credentialId", snapshot.getString("credentialId")); }
    private void refresh() {
        if (device == null || busy) return;
        JSONObject snapshot = device; working("正在核验电脑状态…");
        request(() -> LocalClient.post(snapshot, "status", authBody(snapshot)), response -> {
            boolean confirmed = response.getBoolean("confirmed"); String state = response.getString("state");
            device.put("confirmed", confirmed); save(); idle();
            status.setText(!confirmed ? getString(R.string.pairing_code, device.optString("verificationCode", "请重新配对")) :
                state.equals("locked") ? "电脑已锁屏，可以解锁。" : state.equals("unlocked") ? "电脑已解锁。" : "电脑状态未知，暂不能解锁。");
            unlock.setEnabled(confirmed && state.equals("locked"));
            if(quickUnlock){quickUnlock=false;if(confirmed && state.equals("locked"))unlock();}
        });
    }
    private void unlock() {
        if (device == null || busy) return;
        JSONObject snapshot = device; working("请求本次解锁授权…");
        request(() -> LocalClient.post(snapshot, "challenge", authBody(snapshot)), challenge -> {
            String requestId = challenge.getString("requestId");
            byte[] message = Pairing.message("unlock", requestId, challenge.getString("challenge"), snapshot.getString("credentialId"));
            status.setText("请完成手机系统验证，仅授权本次解锁。");
            authenticate(snapshot.getString("alias"), message, signature -> {
                JSONObject body = authBody(snapshot).put("requestId", requestId).put("signature", Pairing.encode(signature));
                status.setText("正在解锁，请等待电脑确认…");
                request(() -> LocalClient.post(snapshot, "assert", body), response -> {
                    if (!requestId.equals(response.getString("requestId"))) throw new Exception("解锁回执不匹配");
                    idle(); String outcome = response.getString("outcome");
                    status.setText(response.optString("detail", outcome.equals("unlocked") ? "电脑已解锁。" : "未能确认解锁，请检查电脑。"));
                    if(outcome.equals("unlocked") && returnOnSuccess)finish();
                });
            });
        });
    }
    interface Signed { void accept(byte[] signature) throws Exception; }
    private void authenticate(String alias, byte[] message, Signed completion) throws Exception {
        Signature signature = DeviceKey.signer(alias);
        authentication = new CancellationSignal(); int current = generation;
        authenticating = true;
        new BiometricPrompt.Builder(this).setTitle("验证后继续")
            .setSubtitle("仅授权这一次 PocketDesk 操作")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG | BiometricManager.Authenticators.DEVICE_CREDENTIAL)
            .build().authenticate(new BiometricPrompt.CryptoObject(signature), authentication, getMainExecutor(),
                new BiometricPrompt.AuthenticationCallback() {
                    @Override public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult result) {
                        authenticating = false;
                        if (current != generation) return;
                        try { Signature authorized = result.getCryptoObject().getSignature(); authorized.update(message); completion.accept(authorized.sign()); }
                        catch (Exception e) { error(e); }
                    }
                    @Override public void onAuthenticationError(int code, CharSequence message) {
                        authenticating = false;
                        if (current != generation) return;
                        clearTemporaryKey();
                        idle(); status.setText(getString(R.string.auth_canceled, message));
                    }
                });
    }
    @Override protected void onResume() {
        super.onResume();
        // 返回仅核验状态，绝不自动解锁或重试上一次命令。
        if (device != null && !busy && !authenticating) refresh();
    }
    @Override protected void onStop() {
        super.onStop();
        // 系统设备密码界面可能覆盖 Activity；此时保留 CryptoObject，系统取消会回调失败。
        if (authenticating) return;
        generation++;
        if (authentication != null) authentication.cancel();
        if (busy) { idle(); status.setText("操作已中断；如果请求已发出，请检查电脑状态，不会自动重试。"); }
    }
    private void clearTemporaryKey() {
        if (temporaryAlias != null && (device == null || !temporaryAlias.equals(device.optString("alias")))) DeviceKey.delete(temporaryAlias);
        temporaryAlias = null;
    }
    @Override protected void onDestroy() {
        generation++;
        if (authentication != null) authentication.cancel();
        clearTemporaryKey();
        network.shutdownNow(); super.onDestroy();
    }
}
