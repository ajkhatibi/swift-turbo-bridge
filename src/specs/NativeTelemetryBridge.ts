import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface TelemetrySnapshot {
  entityId: string;
  displayName: string;
  batteryOrProgressPercent: number;
  lockState: 'LOCKED' | 'UNLOCKED' | 'TRANSITIONING';
  lastUpdatedTimestamp: number;
}

export interface Spec extends TurboModule {
  /**
   * Atomically persists one snapshot off the JS thread, then requests a widget
   * timeline reload. False means a newer snapshot was already persisted.
   * WidgetKit controls when the reload actually appears on screen.
   */
  syncTelemetryToWidget(snapshot: TelemetrySnapshot): Promise<boolean>;

  /**
   * Starts or updates an iOS 16.2+ Dynamic Island / Lock Screen Live Activity.
   */
  upsertLiveActivity(snapshot: TelemetrySnapshot): Promise<string>;

  /**
   * Ends all active Live Activities when a session or shift completes.
   */
  endAllLiveActivities(): Promise<void>;

  /**
   * Stores a short-lived auth token in the Shared Keychain Access Group
   * so interactive SwiftUI AppIntents can execute authenticated background commands.
   */
  setSharedKeychainToken(token: string, accessGroup: string): boolean;
}

export default TurboModuleRegistry.getEnforcing<Spec>('NativeTelemetryBridge');
