import { EmitterSubscription } from "react-native";

export type PerformanceStatsData = {
    jsFps: number;
    uiFps: number;
    shutter?: number;
    framesDropped?: number;
    usedCpu: number;
    usedRam: number;
    /**
     * @namespace Android
     */
    heapUsedBytes: number | undefined;
    /**
     * @namespace Android
     */
    heapTotalBytes: number | undefined;
}

export type PerformanceStatsThreadData = {
    threads: Array<{
        threadId: number;
        threadName: string;
        totalUserTimeSeconds: number;
        totalSystemTimeSeconds: number;
        totalTimeSeconds: number;
        deltaUserTimeSeconds: number | null;
        deltaSystemTimeSeconds: number | null;
        deltaTimeSeconds: number | null;
    }>;
    uptimeSeconds: number;
    ramTotalBytes: number;
    ramUsedBytes: number;
    ramLoadPercent: number;
}

type PerformanceStatsModule = {
    start: (withCPU?: boolean) => void;
    stop: () => void;
    addListener: (listener: (stats: PerformanceStatsData) => unknown) => EmitterSubscription;
    getPerThreadCPUUsage: () => Promise<PerformanceStatsThreadData>,
}

declare const PerformanceStats: PerformanceStatsModule;
export default PerformanceStats;
