# Node Agent Protocol

The MVP runtime agent still runs on the Rails host, but the control plane now
keeps the boundary explicit so a worker node can move out of process later.

## Authentication

Control-plane and node-agent requests use the same internal bearer-token model
as the gateway. Set `PLATFORM_INTERNAL_TOKEN` for shared internal traffic, or
`NODE_AGENT_SHARED_SECRET` for node-heartbeat-only deployments.

```text
Authorization: Bearer <internal token>
```

## Heartbeat

Node agents report liveness and capacity to:

```text
POST /internal/nodes/heartbeat
```

Payload:

```json
{
  "name": "worker-1",
  "hostname": "worker-1.internal",
  "status": "active",
  "capacity_cpu": "2.0",
  "capacity_memory_bytes": 1073741824
}
```

The local MVP node may send `"local": true` to update the configured local
record. Nodes whose `last_heartbeat_at` is older than
`PLATFORM_NODE_HEARTBEAT_TIMEOUT_SECONDS` are marked `unhealthy` unless they are
already `offline` or `retired`.

## Runtime Commands

Future remote agents should expose the same operations already normalized by
`RuntimeAgent`:

- `start_app`: start a deployment, return runtime/container identity and target.
- `stop_app`: gracefully stop, then force stop after timeout if needed.
- `inspect_app`: return running/stopped/missing state, exit code, and health.
- `get_logs`: stream or page stdout/stderr without exposing secrets.
- `container_status`: lightweight status check for reconciliation.

Start payloads should include app ID, deployment ID, image reference, port,
health-check configuration, environment variables, resource limits, volumes, and
platform labels. Responses should use the existing normalized success/error
shape from `RuntimeAgent::Result`.

## Failure Behavior

Agents must return structured failures rather than raw command output. The
control plane records the failure as an app event, updates the runtime instance,
and leaves the app in a visible failed state such as `wake_failed`, `crashed`,
or `unhealthy`.
