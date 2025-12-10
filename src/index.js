// @flow
import { NativeModules, NativeEventEmitter, Platform } from 'react-native'

const isTurboModuleEnabled = global.__turboModuleProxy != null;

const PerformanceStatsNativeModule = isTurboModuleEnabled ?
  require("./NativePerformanceStats").default :
  NativeModules.PerformanceStats;

// export default PerformanceStatsNativeModule;

export default {
  start: (withCPU = false) => PerformanceStatsNativeModule.start(withCPU),
  stop: () => PerformanceStatsNativeModule.stop(),
  addListener: (listenerCallback) => {
    const eventEmitter = new NativeEventEmitter(PerformanceStatsNativeModule);
    return eventEmitter.addListener("performanceStatsUpdate", listenerCallback);
  },
  getPerThreadCPUUsage: () => {
    if (Platform.OS === 'ios' || Platform.OS === 'android') {
      return PerformanceStatsNativeModule.getPerThreadCPUUsage();
    }

    return Promise.reject(`getPerThreadCPUUsage is not supported on this platform ${Platform.OS}`);
  },
};
