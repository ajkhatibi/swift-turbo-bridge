import { useEffect, useRef, useState } from 'react';
import { Platform } from 'react-native';
import NativeTelemetryBridge from '../specs/NativeTelemetryBridge';
import { type TelemetrySnapshot } from '../specs/NativeTelemetryBridge';
import { validateTelemetrySnapshot } from '../services/WidgetSyncService';

export interface LiveActivityTelemetryState {
  activityId: string | null;
  error: Error | null;
}

// ActivityKit is app-wide. All hook instances share one ordered lifecycle queue;
// an old cleanup must finish before a new owner's start can reach native code.
let lifecycle: Promise<void> = Promise.resolve();
let owner: symbol | undefined;

function enqueue(operation: () => Promise<void>): void {
  lifecycle = lifecycle.then(operation).catch(() => {
    // Each operation publishes its own sanitized error; keep the queue usable.
  });
}

/**
 * Mount once near the session root: the native API ends ALL app activities.
 * Multiple simultaneous enabled owners are rejected rather than ending another
 * screen's activity. Snapshot changes update in place; disable/unmount ends it.
 * iOS 16.2 availability and ActivityKit authorization are enforced natively.
 */
export function useLiveActivityTelemetry(
  snapshot: TelemetrySnapshot | null,
  enabled = true,
): LiveActivityTelemetryState {
  const [state, setState] = useState<LiveActivityTelemetryState>({
    activityId: null,
    error: null,
  });
  const generation = useRef(0);
  const lease = useRef<symbol | undefined>(undefined);
  const active = enabled && snapshot !== null && Platform.OS === 'ios';

  useEffect(() => {
    if (!active) {
      setState({ activityId: null, error: null });
      return;
    }
    const token = Symbol('live-activity-owner');
    lease.current = token;
    let mounted = true;
    enqueue(async () => {
      if (owner !== undefined) {
        if (mounted) setState({ activityId: null, error: new Error('Live Activity already owned') });
        return;
      }
      owner = token;
    });
    return () => {
      mounted = false;
      generation.current += 1;
      lease.current = undefined;
      enqueue(async () => {
        if (owner !== token) return;
        try {
          await NativeTelemetryBridge.endAllLiveActivities();
        } finally {
          owner = undefined;
        }
      });
    };
  }, [active]);

  // Primitive dependencies avoid restarting an activity for a new object identity.
  const entityId = snapshot?.entityId;
  const displayName = snapshot?.displayName;
  const percent = snapshot?.batteryOrProgressPercent;
  const lockState = snapshot?.lockState;
  const timestamp = snapshot?.lastUpdatedTimestamp;
  useEffect(() => {
    if (!active || snapshot === null) return;
    const currentGeneration = ++generation.current;
    const token = lease.current;
    const copy = { ...snapshot };
    enqueue(async () => {
      if (generation.current !== currentGeneration || owner !== token || token === undefined) return;
      try {
        validateTelemetrySnapshot(copy);
        const activityId = await NativeTelemetryBridge.upsertLiveActivity(copy);
        if (generation.current === currentGeneration) setState({ activityId, error: null });
      } catch {
        if (generation.current === currentGeneration) {
          setState({ activityId: null, error: new Error('Live Activity update failed') });
        }
      }
    });
    return () => { generation.current += 1; };
  }, [active, entityId, displayName, percent, lockState, timestamp]);

  return state;
}
