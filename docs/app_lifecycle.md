# App Lifecycle State Machine

The app lifecycle is the shared contract used by the dashboard, gateway, wake
coordinator, runtime agent, and future recovery jobs.

## States

- `created`: The app exists but has not completed its first deployable runtime
  setup.
- `deploying`: A deployment or configuration change is being prepared.
- `sleeping`: No container is currently serving traffic.
- `waking`: A wake attempt is starting or waiting for readiness.
- `running`: The app container is healthy and can receive traffic.
- `draining`: The app is preparing to sleep after idle time, while active
  requests finish.
- `stopping`: A manual or platform stop is in progress.
- `stopped`: The app was intentionally stopped and will not wake automatically
  until policy allows it.
- `crashed`: The runtime exited unexpectedly.
- `unhealthy`: The app was running but failed health checks.
- `wake_failed`: A wake attempt failed before the app became ready.

## Valid Transitions

```text
created -> deploying, sleeping, stopped
deploying -> sleeping, running, wake_failed
sleeping -> waking, stopped
waking -> running, wake_failed, crashed, sleeping
running -> draining, stopping, crashed, unhealthy
draining -> sleeping, running, stopping
stopping -> sleeping, stopped, crashed
stopped -> waking, sleeping
crashed -> waking, stopped, sleeping
unhealthy -> waking, stopping, sleeping
wake_failed -> waking, stopped, sleeping
```

Any transition outside this list is invalid during normal operation. Operators
may use a manual override when the database state must be repaired, but ordinary
application code should use the lifecycle transition API.

## Manual Overrides

Manual overrides are intentionally explicit. They can move an app to any known
state, but the caller must supply a reason so future event logging can preserve
operator intent.

## Platform Restart Restore

Until runtime inspection exists, restart recovery is conservative:

- `waking`, `running`, `draining`, and `stopping` restore to `sleeping`.
- `deploying` restores to `created`.
- Terminal and failure states remain visible.

This prevents the dashboard and gateway from claiming an app is running when the
control plane has not verified the container after restart.
