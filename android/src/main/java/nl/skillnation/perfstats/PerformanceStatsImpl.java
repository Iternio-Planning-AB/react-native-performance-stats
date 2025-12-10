package nl.skillnation.perfstats;


import android.app.ActivityManager;
import android.content.Context;
import android.os.Debug;
import android.os.Handler;
import android.os.SystemClock;
import android.system.Os;
import android.system.OsConstants;
import android.util.Log;

import androidx.annotation.Nullable;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import com.facebook.react.modules.debug.FpsDebugFrameCallback;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

// Most important impl details from: https://github.com/facebook/react-native/blob/main/ReactAndroid/src/main/java/com/facebook/react/devsupport/FpsView.java
public class PerformanceStatsImpl {
    public static final String NAME = "PerformanceStats";
    public static final double SYSTEM_CLK_TCK = Os.sysconf(OsConstants._SC_CLK_TCK);

    private static final int UPDATE_INTERVAL_MS = 1000;

    private final FpsDebugFrameCallback mFrameCallback;
    private final StatsMonitorRunnable mStatsMonitorRunnable;
    private final ReactContext reactContext;
    private Handler handler;
    private final String packageName;
    private final long appLaunchTime = SystemClock.elapsedRealtime();
    private final Map<String, ThreadSample> threadTrackingMap = new HashMap<>();

    long totalRam;

    public PerformanceStatsImpl(ReactContext context) {
        mFrameCallback = new FpsDebugFrameCallback(context);
        mStatsMonitorRunnable = new StatsMonitorRunnable();
        reactContext = context;
        packageName = context.getPackageName();


        ActivityManager.MemoryInfo memoryInfo = new ActivityManager.MemoryInfo();
        ActivityManager activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        activityManager.getMemoryInfo(memoryInfo);
        totalRam = memoryInfo.totalMem;
    }

    // Config
    private boolean withCPU = false;

    public void start(Boolean withCPU) {
        this.withCPU = withCPU;
        handler = new Handler();
        mFrameCallback.reset();
        mFrameCallback.start();
        mStatsMonitorRunnable.start();
    }

    public void stop() {
        handler = null;
        mFrameCallback.stop();
        mStatsMonitorRunnable.stop();
    }

    private void setCurrentStats(double uiFPS, double jsFPS, int framesDropped, int shutters, double usedRam, double usedCpu, double heapUsedBytes, double heapTotalBytes) {
        WritableMap state = Arguments.createMap();
        state.putDouble("uiFps", uiFPS);
        state.putDouble("jsFps", jsFPS);
        state.putInt("framesDropped", framesDropped);
        state.putInt("shutters", shutters);
        state.putDouble("usedRam", usedRam);
        state.putDouble("usedCpu", usedCpu);
        state.putDouble("heapUsedBytes", heapUsedBytes);
        state.putDouble("heapTotalBytes", heapTotalBytes);

        sendEvent(state);
    }

    private void sendEvent(@Nullable Object data) {
        if (reactContext == null) {
            return;
        }

        if (!reactContext.hasActiveReactInstance()) {
            return;
        }
        reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class).emit("performanceStatsUpdate", data);
    }

    // NOTE: may not be exactly the same as seen in Profiler, as graphics can't be retrieved.
    // Read here: https://developer.android.com/reference/android/os/Debug#getMemoryInfo(android.os.Debug.MemoryInfo)
    private double getUsedRam() {
        Debug.MemoryInfo memoryInfo = new Debug.MemoryInfo();
        Debug.getMemoryInfo(memoryInfo);

        return memoryInfo.getTotalPss();
    }

    public WritableMap getPerThreadCPUUsage() {
        WritableArray threadStats = Arguments.createArray();
        double now = SystemClock.elapsedRealtime() / 1000.0;

        File taskDir = new File("/proc/self/task");
        File[] threads = taskDir.listFiles();
        Set<String> activeThreadIds = new HashSet<>();

        if (threads != null) {
            for (File threadDir : threads) {
                String threadId = threadDir.getName();
                File statFile = new File(threadDir, "stat");

                try (BufferedReader reader = new BufferedReader(new FileReader(statFile))) {
                    String line = reader.readLine();

                    if (line == null) {
                        continue;
                    }

                    String[] parts = line.split(" ");

                    if (parts.length < 15) {
                        continue;
                    }

                    String threadName = parts[1];

                    double userTime = Long.parseLong(parts[13]) / SYSTEM_CLK_TCK;
                    double systemTime = Long.parseLong(parts[14]) / SYSTEM_CLK_TCK;

                    ThreadSample sample = threadTrackingMap.get(threadId);
                    if (sample == null) {
                        sample = new ThreadSample(threadId, threadName, userTime, systemTime, now);
                        threadTrackingMap.put(threadId, sample);
                    } else {
                        sample.update(userTime, systemTime, now);
                    }

                    activeThreadIds.add(threadId);
                    threadStats.pushMap(sample.toWritableMap());
                } catch (IOException | ArrayIndexOutOfBoundsException | NumberFormatException e) {
                    Log.e(NAME, "error fetching thread stats", e);
                }
            }
        }

        double usedRam = getUsedRam();

        WritableMap stats = Arguments.createMap();
        stats.putArray("threads", threadStats);
        stats.putDouble("ramTotalBytes", totalRam);
        stats.putDouble("ramUsedBytes", usedRam);
        stats.putDouble("ramLoadPercent", (usedRam / totalRam) * 100.0);
        stats.putDouble("uptimeSeconds", (SystemClock.elapsedRealtime() - appLaunchTime) / 1000.0);

        threadTrackingMap.keySet().removeIf(tid -> !activeThreadIds.contains(tid));

        return stats;
    }

    /** Timer that runs every UPDATE_INTERVAL_MS ms and updates the currently displayed FPS and resource usages. */
    private class StatsMonitorRunnable implements Runnable {

        private boolean mShouldStop = false;
        private int mTotalFramesDropped = 0;
        private int mTotal4PlusFrameStutters = 0;

        @Override
        public void run() {
            if (mShouldStop) {
                return;
            }
            // Collect FPS info
            mTotalFramesDropped += mFrameCallback.getExpectedNumFrames() - mFrameCallback.getNumFrames();
            mTotal4PlusFrameStutters += mFrameCallback.get4PlusFrameStutters();
            double fps = mFrameCallback.getFps();
            double jsFps = mFrameCallback.getJsFPS();

            // Collect system resource usage
            double cpuUsage = 0;
            if (withCPU) {
                try {
                    cpuUsage = getUsedCPU();
                } catch (Exception e) {
                }
            }
            double usedRam = getUsedRam() / 1024D;
            Runtime runtime = Runtime.getRuntime();
            double heapUsedBytes = runtime.totalMemory() - runtime.freeMemory();
            double heapTotalBytes = runtime.totalMemory();

            setCurrentStats(
                    fps,
                    jsFps,
                    mTotalFramesDropped,
                    mTotal4PlusFrameStutters,
                    usedRam,
                    cpuUsage,
                    heapUsedBytes,
                    heapTotalBytes
            );
            mFrameCallback.reset();

            // TODO: not sure if we need to run that on a view
            handler.postDelayed(this, UPDATE_INTERVAL_MS);
        }

        public void start() {
            mShouldStop = false;
            handler.post(this);

            getPerThreadCPUUsage();
        }

        public void stop() {
            mShouldStop = true;
        }

        private double getUsedCPU() throws IOException {
            String[] commands = { "top", "-n", "1", "-q", "-oCMDLINE,%CPU", "-s2", "-b" };
            BufferedReader reader = new BufferedReader(
                    new InputStreamReader(Runtime.getRuntime().exec(commands).getInputStream())
            );
            String line;
            double cpuUsage = 0;
            while ((line = reader.readLine()) != null) {
                if (!line.contains(packageName)) continue;
                line = line.replace(packageName, "").replaceAll(" ", "");
                cpuUsage = Double.parseDouble(line);
                break;
            }
            reader.close();
            return cpuUsage;
        }
    }
}
