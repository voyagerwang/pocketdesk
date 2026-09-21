/**
 * [INPUT]: 安卓测试运行类路径，包含最终扫码页引用的 AndroidX 依赖。
 * [OUTPUT]: 防止只编译通过、扫码时才因缺失权限或 Fragment 类而退出。
 * [POS]: 扫码发布依赖回归；不代表相机硬件和真机权限流程已验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;
import org.junit.Test;
import static org.junit.Assert.*;

public class ScannerDependenciesTest {
    @Test public void scannerRuntimeClassesArePackaged() throws Exception {
        ClassLoader loader = getClass().getClassLoader();
        for (String name : new String[]{"androidx.core.content.ContextCompat", "androidx.core.app.ActivityCompat",
                "androidx.fragment.app.Fragment", "androidx.fragment.app.FragmentActivity",
                "com.journeyapps.barcodescanner.CaptureActivity", "com.journeyapps.barcodescanner.CaptureManager"}) {
            assertNotNull(name, Class.forName(name, false, loader));
        }
    }
}
