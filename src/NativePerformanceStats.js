// @flow
import type { TurboModule } from 'react-native/Libraries/TurboModule/RCTExport';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  start(withCPU?: boolean): void;
  stop(): void;
  getPerThreadCPUUsage: () => Promise<any>;
}
export default (TurboModuleRegistry.get<Spec>(
  'PerformanceStats'
): ?Spec);
