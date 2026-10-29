import { createElement } from 'react';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import NativeTelemetryBridge, { type Spec, type TelemetrySnapshot } from '../src/specs/NativeTelemetryBridge';
import { useLiveActivityTelemetry, type LiveActivityTelemetryState } from '../src/hooks/useLiveActivityTelemetry';

jest.mock('react-native', () => ({
  Platform: { OS: 'ios' },
  TurboModuleRegistry: {
    getEnforcing: () => ({
      syncTelemetryToWidget: jest.fn(),
      upsertLiveActivity: jest.fn(),
      endAllLiveActivities: jest.fn(),
      setSharedKeychainToken: jest.fn(),
    }),
  },
}));

// Required by React 19 to make async effects deterministic under act().
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const bridge = NativeTelemetryBridge as jest.Mocked<Spec>;
const snapshot: TelemetrySnapshot = {
  entityId: 'vehicle-1', displayName: 'Vehicle', batteryOrProgressPercent: 50,
  lockState: 'LOCKED', lastUpdatedTimestamp: 1,
};

let latest: LiveActivityTelemetryState;
function Harness({ value, enabled = true }: { value: TelemetrySnapshot | null; enabled?: boolean }): null {
  latest = useLiveActivityTelemetry(value, enabled);
  return null;
}

describe('useLiveActivityTelemetry', () => {
  const roots: ReactTestRenderer[] = [];
  beforeEach(() => {
    bridge.upsertLiveActivity.mockReset().mockResolvedValue('activity-1');
    bridge.endAllLiveActivities.mockReset().mockResolvedValue(undefined);
  });
  afterEach(async () => {
    await act(async () => { for (const root of roots.splice(0)) root.unmount(); });
  });

  async function mount(value: TelemetrySnapshot | null, enabled = true): Promise<ReactTestRenderer> {
    let root!: ReactTestRenderer;
    await act(async () => { root = create(createElement(Harness, { value, enabled })); });
    roots.push(root);
    return root;
  }

  it('starts, updates without ending, and ends on disable', async () => {
    const root = await mount(snapshot);
    expect(latest).toEqual({ activityId: 'activity-1', error: null });
    await act(async () => { root.update(createElement(Harness, { value: { ...snapshot, lastUpdatedTimestamp: 2 } })); });
    expect(bridge.upsertLiveActivity).toHaveBeenCalledTimes(2);
    expect(bridge.endAllLiveActivities).not.toHaveBeenCalled();
    await act(async () => { root.update(createElement(Harness, { value: snapshot, enabled: false })); });
    expect(bridge.endAllLiveActivities).toHaveBeenCalledTimes(1);
    expect(latest).toEqual({ activityId: null, error: null });
  });

  it('ignores object identity changes and does not start for null', async () => {
    const root = await mount(null);
    expect(bridge.upsertLiveActivity).not.toHaveBeenCalled();
    await act(async () => { root.update(createElement(Harness, { value: snapshot })); });
    await act(async () => { root.update(createElement(Harness, { value: { ...snapshot } })); });
    expect(bridge.upsertLiveActivity).toHaveBeenCalledTimes(1);
  });

  it('sanitizes update failure and recovers on the next snapshot', async () => {
    bridge.upsertLiveActivity.mockRejectedValueOnce(new Error('secret'));
    const root = await mount(snapshot);
    expect(latest.error?.message).toBe('Live Activity update failed');
    await act(async () => { root.update(createElement(Harness, { value: { ...snapshot, lastUpdatedTimestamp: 2 } })); });
    expect(latest).toEqual({ activityId: 'activity-1', error: null });
  });

  it('rejects a second owner without ending the first owner activity', async () => {
    await mount(snapshot);
    const other = await mount(snapshot);
    expect(latest.error?.message).toBe('Live Activity already owned');
    expect(bridge.upsertLiveActivity).toHaveBeenCalledTimes(1);
    await act(async () => { other.unmount(); });
    expect(bridge.endAllLiveActivities).not.toHaveBeenCalled();
  });

  it('waits for pending native start before ending on unmount', async () => {
    let finish!: (id: string) => void;
    bridge.upsertLiveActivity.mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }));
    const root = await mount(snapshot);
    await act(async () => { root.unmount(); });
    expect(bridge.endAllLiveActivities).not.toHaveBeenCalled();
    await act(async () => { finish('late-activity'); });
    expect(bridge.endAllLiveActivities).toHaveBeenCalledTimes(1);
  });

  it('orders a rapid disable and re-enable after pending cleanup', async () => {
    const root = await mount(snapshot);
    let finish!: () => void;
    bridge.endAllLiveActivities.mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }));
    await act(async () => { root.update(createElement(Harness, { value: null })); });
    await act(async () => { root.update(createElement(Harness, { value: snapshot })); });
    expect(bridge.upsertLiveActivity).toHaveBeenCalledTimes(1);
    await act(async () => { finish(); });
    expect(bridge.upsertLiveActivity).toHaveBeenCalledTimes(2);
    expect(latest.activityId).toBe('activity-1');
  });

  it('releases the owner and queue even if native cleanup rejects', async () => {
    const root = await mount(snapshot);
    bridge.endAllLiveActivities.mockRejectedValueOnce(new Error('cleanup failed'));
    await act(async () => { root.update(createElement(Harness, { value: null })); });
    await act(async () => { root.update(createElement(Harness, { value: snapshot })); });
    expect(bridge.upsertLiveActivity).toHaveBeenCalledTimes(2);
    expect(latest).toEqual({ activityId: 'activity-1', error: null });
  });

  it('does not pass invalid snapshots to ActivityKit', async () => {
    await mount({ ...snapshot, batteryOrProgressPercent: NaN });
    expect(bridge.upsertLiveActivity).not.toHaveBeenCalled();
    expect(latest.error?.message).toBe('Live Activity update failed');
  });
});
