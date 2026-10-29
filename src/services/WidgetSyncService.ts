import NativeTelemetryBridge, {
  type Spec,
  type TelemetrySnapshot,
} from '../specs/NativeTelemetryBridge';

type Waiter = {
  resolve: (accepted: boolean) => void;
  reject: (error: Error) => void;
};

type Batch = {
  snapshot: TelemetrySnapshot;
  waiters: Waiter[];
};

/** Deliberately excludes native errors, which may contain sensitive payloads. */
export class WidgetSyncError extends Error {
  constructor(public readonly code: 'INVALID_SNAPSHOT' | 'QUEUE_FULL' | 'NATIVE_FAILURE') {
    super(`Widget synchronization failed: ${code}`);
    this.name = 'WidgetSyncError';
  }
}

/** Validate before entering the JSI boundary; native code validates independently. */
export function validateTelemetrySnapshot(snapshot: TelemetrySnapshot): void {
  if (
    typeof snapshot?.entityId !== 'string' ||
    snapshot.entityId.trim().length === 0 ||
    snapshot.entityId.length > 256 ||
    /[\u0000-\u001f\u007f-\u009f]/.test(snapshot.entityId) ||
    typeof snapshot.displayName !== 'string' ||
    snapshot.displayName.trim().length === 0 ||
    snapshot.displayName.length > 256 ||
    /[\u0000-\u001f\u007f-\u009f]/.test(snapshot.displayName) ||
    !Number.isFinite(snapshot.batteryOrProgressPercent) ||
    snapshot.batteryOrProgressPercent < 0 ||
    snapshot.batteryOrProgressPercent > 100 ||
    !['LOCKED', 'UNLOCKED', 'TRANSITIONING'].includes(snapshot.lockState) ||
    !Number.isSafeInteger(snapshot.lastUpdatedTimestamp) ||
    snapshot.lastUpdatedTimestamp < 0
  ) {
    throw new WidgetSyncError('INVALID_SNAPSHOT');
  }
}

/**
 * A bounded FIFO for native persistence, not an OS background scheduler.
 * Adjacent updates for the same entity in one JS turn collapse into one atomic
 * snapshot; every caller observes that batch's result. Entity switches retain
 * order. A failed batch rejects its callers without poisoning subsequent work.
 */
export class WidgetSyncService {
  private readonly queue: Batch[] = [];
  private running = false;
  private scheduled = false;
  private idleWaiters: Array<() => void> = [];
  private pendingCalls = 0;

  constructor(
    private readonly bridge: Spec = NativeTelemetryBridge,
    private readonly maxPendingCalls = 256,
  ) {
    if (!Number.isSafeInteger(maxPendingCalls) || maxPendingCalls < 1) {
      throw new RangeError('maxPendingCalls must be a positive safe integer');
    }
  }

  syncTelemetryToWidget(snapshot: TelemetrySnapshot): Promise<boolean> {
    try {
      validateTelemetrySnapshot(snapshot);
    } catch (error) {
      return Promise.reject(error);
    }
    if (this.pendingCalls >= this.maxPendingCalls) {
      return Promise.reject(new WidgetSyncError('QUEUE_FULL'));
    }

    // Copy explicitly: caller mutations and extra JS properties never cross JSI.
    const copy: TelemetrySnapshot = {
      entityId: snapshot.entityId,
      displayName: snapshot.displayName,
      batteryOrProgressPercent: snapshot.batteryOrProgressPercent,
      lockState: snapshot.lockState,
      lastUpdatedTimestamp: snapshot.lastUpdatedTimestamp,
    };
    this.pendingCalls += 1;
    const result = new Promise<boolean>((resolve, reject) => {
      const tail = this.queue[this.queue.length - 1];
      if (tail?.snapshot.entityId === copy.entityId) {
        if (copy.lastUpdatedTimestamp > tail.snapshot.lastUpdatedTimestamp) {
          tail.snapshot = copy;
        }
        tail.waiters.push({ resolve, reject });
      } else {
        this.queue.push({ snapshot: copy, waiters: [{ resolve, reject }] });
      }
    });
    if (!this.running && !this.scheduled) {
      this.scheduled = true;
      // Defer one turn to coalesce bursts without holding the JS thread.
      void Promise.resolve().then(() => this.drain());
    }
    return result;
  }

  /** Resolves at the next idle point, including work enqueued during a write. */
  flush(): Promise<void> {
    if (!this.running && !this.scheduled && this.queue.length === 0) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve) => this.idleWaiters.push(resolve));
  }

  private async drain(): Promise<void> {
    this.scheduled = false;
    this.running = true;
    let batch: Batch | undefined;
    while ((batch = this.queue.shift()) !== undefined) {
      try {
        const accepted = await this.bridge.syncTelemetryToWidget(batch.snapshot);
        for (const waiter of batch.waiters) waiter.resolve(accepted);
      } catch {
        for (const waiter of batch.waiters) {
          waiter.reject(new WidgetSyncError('NATIVE_FAILURE'));
        }
      } finally {
        this.pendingCalls -= batch.waiters.length;
      }
    }
    this.running = false;
    const waiters = this.idleWaiters;
    this.idleWaiters = [];
    for (const resolve of waiters) resolve();
  }
}

export const widgetSyncService = new WidgetSyncService();
