/**
 * [INPUT]: Android 加速度计、旋转向量、当前受信工作台 WebView 与 Activity 生命周期。
 * [OUTPUT]: 仅在已连接 PocketDesk 顶层页面请求时采集姿态，并向该页面派发 pocketdesk-native-motion 样本。
 * [POS]: HTTP WebView 的甩送传感器适配层；不识别手势、不提交草稿、不向网页暴露通用原生能力。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
package dev.pocketdesk.mobile;

import android.app.Activity;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.view.Surface;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;

final class NativeMotionBridge implements SensorEventListener {
    static final String NAME = "PocketDeskMotionNative";
    private final Activity activity;
    private final WebView web;
    private final SensorManager sensors;
    private final Sensor acceleration;
    private final Sensor rotation;
    private boolean active;
    private float accelerationMagnitude = 9.8f;

    NativeMotionBridge(Activity activity, WebView web) {
        this.activity = activity;
        this.web = web;
        sensors = (SensorManager)activity.getSystemService(Activity.SENSOR_SERVICE);
        acceleration = sensors == null ? null : sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
        rotation = sensors == null ? null : sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR);
    }

    @JavascriptInterface public boolean available() {
        return acceleration != null && rotation != null;
    }

    @JavascriptInterface public boolean running() {
        return active;
    }

    @JavascriptInterface public void start() {
        activity.runOnUiThread(() -> {
            if (active || !available() || !trustedPage()) return;
            boolean accel = sensors.registerListener(this, acceleration, SensorManager.SENSOR_DELAY_GAME);
            boolean orient = sensors.registerListener(this, rotation, SensorManager.SENSOR_DELAY_GAME);
            active = accel && orient;
            if (!active) sensors.unregisterListener(this);
        });
    }

    @JavascriptInterface public void stop() {
        activity.runOnUiThread(this::stopOnUiThread);
    }

    void stopOnUiThread() {
        if (sensors != null) sensors.unregisterListener(this);
        active = false;
    }

    private boolean trustedPage() {
        return activity instanceof MainActivity
            && ((MainActivity)activity).ownsWorkspacePage(web.getUrl());
    }

    @Override public void onSensorChanged(SensorEvent event) {
        if (!active || !trustedPage()) { stopOnUiThread(); return; }
        if (event.sensor.getType() == Sensor.TYPE_ACCELEROMETER) {
            float x = event.values[0], y = event.values[1], z = event.values[2];
            accelerationMagnitude = (float)Math.sqrt(x * x + y * y + z * z);
            return;
        }
        if (event.sensor.getType() != Sensor.TYPE_ROTATION_VECTOR) return;
        float[] matrix = new float[9], radians = new float[3];
        SensorManager.getRotationMatrixFromVector(matrix, event.values);
        SensorManager.getOrientation(matrix, radians);
        float[] angles = orientationDegrees(radians);
        String script = "window.dispatchEvent(new CustomEvent('pocketdesk-native-motion',{detail:{t:"
            + (event.timestamp / 1_000_000.0) + ",alpha:" + angles[0] + ",beta:" + angles[1]
            + ",gamma:" + angles[2] + ",accel:" + accelerationMagnitude + ",screenAngle:"
            + screenAngle(activity.getWindowManager().getDefaultDisplay().getRotation()) + "}}))";
        web.evaluateJavascript(script, null);
    }

    static float[] orientationDegrees(float[] radians) {
        float alpha = (float)Math.toDegrees(radians[0]);
        if (alpha < 0) alpha += 360f;
        return new float[]{alpha, (float)-Math.toDegrees(radians[1]), (float)Math.toDegrees(radians[2])};
    }

    static int screenAngle(int rotation) {
        if (rotation == Surface.ROTATION_90) return 90;
        if (rotation == Surface.ROTATION_180) return 180;
        if (rotation == Surface.ROTATION_270) return 270;
        return 0;
    }

    @Override public void onAccuracyChanged(Sensor sensor, int accuracy) {}
}
