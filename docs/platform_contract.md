# MVP Hosting Contract

HobbyRepository v1 hosts HTTP container apps on a single machine. The platform is
the control plane, wake coordinator, and dashboard; app containers run on the
local container runtime and may sleep when idle.

## Supported App Type

The MVP supports one process type: an HTTP container app.

An app must:

- Start from a prebuilt container image.
- Listen for HTTP traffic on its configured internal port.
- Bind to all interfaces inside the container, not only localhost.
- Become ready before the startup timeout expires.
- Treat the container filesystem as ephemeral unless a persistent volume is
  explicitly configured.

Background workers, cron jobs, arbitrary TCP services, multi-process releases,
and horizontal scaling are outside the v1 hosting contract.

## Defaults

- Idle timeout: 900 seconds.
- Startup timeout: 60 seconds.
- Health check path: `/`.
- Health check behavior: HTTP success is preferred; later runtime work may add a
  port-open fallback for apps without a health endpoint.

## Cold Starts

Apps may be sleeping when traffic arrives. On a cold request, the gateway or
activator asks the Rails control plane to wake the app, the platform starts the
current container deployment, waits for readiness, and only then routes traffic.

Cold starts are bounded. If the app does not start and become healthy before the
startup timeout, the request may fail with an unavailable response and the app is
marked `wake_failed` or another visible failure state.

## Startup Failures

Startup can fail because the image cannot be pulled, the container exits, the app
does not listen on the configured port, or the health check never succeeds. The
platform records the failure state and leaves the app visible in the dashboard so
the owner can inspect what happened.

## Persistence

Persistent data is limited to platform records, configured environment data,
runtime metadata, app events, logs retained by the platform, and explicitly
configured persistent volumes.

The local filesystem inside an app container is ephemeral. Any file written
outside a configured volume can disappear when the app sleeps, restarts, crashes,
or is redeployed.

## Single-Node Boundary

The MVP runs on one local node. Every app is assigned to that node and every
runtime instance records the node where its container runs. The schema keeps node
identity explicit so future work can add more nodes without changing the core app
and runtime records.
