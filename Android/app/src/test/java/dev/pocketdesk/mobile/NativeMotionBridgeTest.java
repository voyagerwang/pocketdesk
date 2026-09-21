/**
 * [INPUT]: NativeMotionBridge 的纯角度与屏幕方向映射。
 * [OUTPUT]: Android 旋转向量结果稳定转换为现有 Web 识别器的 alpha/beta/gamma/screenAngle 契约。
 * [POS]: 不读取真机传感器的 JVM 回归；真实方向符号与手感仍需真机验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;

import android.view.Surface;
import org.junit.Test;
import static org.junit.Assert.*;

public class NativeMotionBridgeTest {
    @Test public void convertsAndroidOrientationToWebDegrees() {
        float[] angles = NativeMotionBridge.orientationDegrees(new float[]{(float)-Math.PI / 2, (float)Math.PI / 6, (float)-Math.PI / 4});
        assertEquals(270f, angles[0], 0.01f);
        assertEquals(-30f, angles[1], 0.01f);
        assertEquals(-45f, angles[2], 0.01f);
    }

    @Test public void mapsAllDisplayRotations() {
        assertEquals(0, NativeMotionBridge.screenAngle(Surface.ROTATION_0));
        assertEquals(90, NativeMotionBridge.screenAngle(Surface.ROTATION_90));
        assertEquals(180, NativeMotionBridge.screenAngle(Surface.ROTATION_180));
        assertEquals(270, NativeMotionBridge.screenAngle(Surface.ROTATION_270));
    }
}
