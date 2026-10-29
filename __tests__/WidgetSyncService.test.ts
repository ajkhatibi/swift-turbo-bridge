import { TurboModuleRegistry } from 'react-native';
import NativeTelemetryBridge, { type Spec, type TelemetrySnapshot } from '../src/specs/NativeTelemetryBridge';
import { WidgetSyncError, WidgetSyncService } from '../src/services/WidgetSyncService';

jest.mock('react-native', () => ({
  TurboModuleRegistry: {
    getEnforcing: jest.fn(() => ({
      syncTelemetryToWidget: jest.fn(),
      upsertLiveActivity: jest.fn(),
      endAllLiveActivities: jest.fn(),
      setSharedKeychainToken: jest.fn(),
    })),
  },
}));

const bridge = NativeTelemetryBridge as jest.Mocked<Spec>;
const snapshot = (timestamp = 1, entityId = 'vehicle-1'): TelemetrySnapshot => ({
  entityId,
  displayName: 'Fleet vehicle',
  batteryOrProgressPercent: 82.5,
  lockState: 'LOCKED',
  lastUpdatedTimestamp: timestamp,
});

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: Error) => void;
} {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

describe('WidgetSyncService', () => {
  let service: WidgetSyncService;
  beforeEach(() => {
    bridge.syncTelemetryToWidget.mockReset().mockResolvedValue(true);
    service = new WidgetSyncService();
  });

  it('uses the Codegen TurboModule name', () => {
    jest.isolateModules(() => {
      require('../src/specs/NativeTelemetryBridge');
      const { TurboModuleRegistry: registry } = require('react-native') as {
        TurboModuleRegistry: typeof TurboModuleRegistry;
      };
      expect(registry.getEnforcing).toHaveBeenCalledWith('NativeTelemetryBridge');
    });
  });

  it('coalesces a synchronous burst into the newest complete snapshot', async () => {
    const calls = [1, 3, 2].map((time) => service.syncTelemetryToWidget(snapshot(time)));
    await expect(Promise.all(calls)).resolves.toEqual([true, true, true]);
    expect(bridge.syncTelemetryToWidget).toHaveBeenCalledTimes(1);
    expect(bridge.syncTelemetryToWidget).toHaveBeenCalledWith(snapshot(3));
  });

  it('does not replace a pending snapshot on an equal timestamp', async () => {
    const first = service.syncTelemetryToWidget(snapshot());
    const second = service.syncTelemetryToWidget({ ...snapshot(), lockState: 'UNLOCKED' });
    await Promise.all([first, second]);
    expect(bridge.syncTelemetryToWidget).toHaveBeenCalledWith(snapshot());
  });

  it('copies caller-owned data before scheduling the native call', async () => {
    const input = snapshot();
    const pending = service.syncTelemetryToWidget(input);
    input.entityId = 'mutated';
    input.batteryOrProgressPercent = -1;
    await pending;
    expect(bridge.syncTelemetryToWidget).toHaveBeenCalledWith(snapshot());
  });

  it('retains entity switches rather than batching across them', async () => {
    await Promise.all([
      service.syncTelemetryToWidget(snapshot(1, 'a')),
      service.syncTelemetryToWidget(snapshot(2, 'b')),
      service.syncTelemetryToWidget(snapshot(3, 'a')),
    ]);
    expect(bridge.syncTelemetryToWidget.mock.calls.map(([value]) => value.entityId)).toEqual(['a', 'b', 'a']);
  });

  it('serializes in-flight writes and batches only queued updates', async () => {
    const firstWrite = deferred<boolean>();
    bridge.syncTelemetryToWidget.mockReturnValueOnce(firstWrite.promise);
    const first = service.syncTelemetryToWidget(snapshot(1));
    await Promise.resolve();
    const second = service.syncTelemetryToWidget(snapshot(2));
    const third = service.syncTelemetryToWidget(snapshot(3));
    expect(bridge.syncTelemetryToWidget).toHaveBeenCalledTimes(1);
    firstWrite.resolve(true);
    await Promise.all([first, second, third]);
    expect(bridge.syncTelemetryToWidget.mock.calls.map(([value]) => value.lastUpdatedTimestamp)).toEqual([1, 3]);
  });

  it('propagates stale native rejection without inventing success', async () => {
    bridge.syncTelemetryToWidget.mockResolvedValueOnce(false);
    await expect(service.syncTelemetryToWidget(snapshot())).resolves.toBe(false);
  });

  it('rejects every caller in a failed batch with a sanitized error', async () => {
    bridge.syncTelemetryToWidget.mockRejectedValueOnce(new Error('sensitive backend details'));
    const results = await Promise.allSettled([
      service.syncTelemetryToWidget(snapshot(1)),
      service.syncTelemetryToWidget(snapshot(2)),
    ]);
    for (const result of results) {
      expect(result.status).toBe('rejected');
      if (result.status === 'rejected') {
        expect(result.reason).toEqual(new WidgetSyncError('NATIVE_FAILURE'));
        expect(String(result.reason)).not.toContain('sensitive');
      }
    }
  });

  it('continues processing after a failed native write', async () => {
    bridge.syncTelemetryToWidget.mockRejectedValueOnce(new Error('failed'));
    const first = service.syncTelemetryToWidget(snapshot(1, 'a'));
    const second = service.syncTelemetryToWidget(snapshot(2, 'b'));
    await expect(first).rejects.toMatchObject({ code: 'NATIVE_FAILURE' });
    await expect(second).resolves.toBe(true);
    await expect(service.syncTelemetryToWidget(snapshot(3))).resolves.toBe(true);
  });

  it('handles a synchronous JSI throw and remains usable', async () => {
    bridge.syncTelemetryToWidget.mockImplementationOnce(() => { throw new Error('JSI'); });
    await expect(service.syncTelemetryToWidget(snapshot())).rejects.toMatchObject({ code: 'NATIVE_FAILURE' });
    await expect(service.syncTelemetryToWidget(snapshot(2))).resolves.toBe(true);
  });

  it('flush waits for in-flight work and all queued work', async () => {
    const write = deferred<boolean>();
    bridge.syncTelemetryToWidget.mockReturnValueOnce(write.promise);
    const first = service.syncTelemetryToWidget(snapshot());
    const idle = jest.fn();
    const flush = service.flush().then(idle);
    await Promise.resolve();
    const second = service.syncTelemetryToWidget(snapshot(2));
    expect(idle).not.toHaveBeenCalled();
    write.resolve(true);
    await Promise.all([first, second, flush]);
    expect(idle).toHaveBeenCalledTimes(1);
    await expect(service.flush()).resolves.toBeUndefined();
  });

  it('flush resolves after failure without hiding individual request failure', async () => {
    bridge.syncTelemetryToWidget.mockRejectedValueOnce(new Error('failed'));
    const pending = service.syncTelemetryToWidget(snapshot());
    const rejection = expect(pending).rejects.toBeInstanceOf(WidgetSyncError);
    await expect(service.flush()).resolves.toBeUndefined();
    await rejection;
  });

  it('bounds callers even if all updates would coalesce, then frees capacity', async () => {
    service = new WidgetSyncService(bridge, 2);
    const first = service.syncTelemetryToWidget(snapshot(1));
    const second = service.syncTelemetryToWidget(snapshot(2));
    await expect(service.syncTelemetryToWidget(snapshot(3))).rejects.toMatchObject({ code: 'QUEUE_FULL' });
    await Promise.all([first, second]);
    await expect(service.syncTelemetryToWidget(snapshot(4))).resolves.toBe(true);
  });

  it.each([0, -1, 1.5, Infinity, NaN])('rejects invalid queue limit %s', (limit) => {
    expect(() => new WidgetSyncService(bridge, limit)).toThrow(RangeError);
  });

  it.each<Partial<TelemetrySnapshot>>([
    { entityId: '' }, { entityId: '  ' }, { entityId: 'x'.repeat(257) },
    { entityId: 'vehicle\n1' }, { entityId: 'vehicle\u0085' },
    { displayName: '' }, { displayName: '  ' }, { displayName: 'x'.repeat(257) },
    { displayName: 'Vehicle\u0000' },
    { batteryOrProgressPercent: -1 }, { batteryOrProgressPercent: 101 },
    { batteryOrProgressPercent: NaN }, { batteryOrProgressPercent: Infinity },
    { lastUpdatedTimestamp: -1 }, { lastUpdatedTimestamp: 1.1 },
    { lastUpdatedTimestamp: Number.MAX_SAFE_INTEGER + 1 },
    { lastUpdatedTimestamp: NaN },
  ])('rejects invalid telemetry %j without crossing JSI', async (invalid) => {
    await expect(service.syncTelemetryToWidget({ ...snapshot(), ...invalid }))
      .rejects.toMatchObject({ code: 'INVALID_SNAPSHOT' });
    expect(bridge.syncTelemetryToWidget).not.toHaveBeenCalled();
  });

  it('rejects unknown enum values and malformed runtime payloads', async () => {
    for (const invalid of [null, {}, { ...snapshot(), lockState: 'UNKNOWN' }]) {
      await expect(service.syncTelemetryToWidget(invalid as TelemetrySnapshot))
        .rejects.toMatchObject({ code: 'INVALID_SNAPSHOT' });
    }
  });

  it.each([0, 100])('accepts percentage boundary %s and epoch zero', async (percent) => {
    await expect(service.syncTelemetryToWidget({
      ...snapshot(0), batteryOrProgressPercent: percent,
    })).resolves.toBe(true);
  });
});
