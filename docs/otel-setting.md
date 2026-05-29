# Sending data to this stack

This document covers how to wire each supported AI agent — **Claude Code**, **OpenCode**, **Hermes** —
to the local OTel collector so its metrics and logs show up in Grafana.

The stack itself is described in the [top-level README](../README.md). This page focuses on the **sender side**:
what environment variables to set, where to set them, and how to verify the data is flowing.

## Collector endpoint summary

The OTLP receivers are exposed on **all interfaces** (`0.0.0.0`), so other machines on the
LAN/VPN — and a front-facing reverse proxy — can reach them. Replace `<COLLECTOR_HOST>` with
the collector machine's IP or hostname (use `127.0.0.1` when the sender runs on the same box).

| Protocol | Endpoint | Port | Use when |
|---|---|---|---|
| OTLP gRPC | `http://<COLLECTOR_HOST>:4317` | 4317 | Default for many native OTel SDKs (Hermes) |
| OTLP HTTP / protobuf | `http://<COLLECTOR_HOST>:4318` | 4318 | Used by Claude Code, recommended for OpenCode |
| Health check | `http://127.0.0.1:13133` | 13133 | Verify collector is up (loopback-only, no auth) |

Container-to-container senders inside the same docker network use the service name `obs-otel-collector:4317` or `:4318` instead.

### Authentication (required)

Both OTLP receivers enforce a **static bearer token**. Every sender must present:

```
Authorization: Bearer <OTEL_AUTH_TOKEN>
```

- The token lives in `.env` on the collector host (`OTEL_AUTH_TOKEN=...`, gitignored). Generate one with `openssl rand -hex 32` and `docker compose up -d`.
- Requests without a valid token are rejected with **HTTP 401** (gRPC `UNAUTHENTICATED`).
- This stack (collector 0.116.1) supports a **single** shared token; per-machine tokens require collector ≥ 0.122.
- The token travels in plaintext over HTTP/gRPC — fine on a trusted LAN/VPN. For untrusted networks, terminate TLS at a reverse proxy in front of the collector.

The exact env var to carry this header differs per agent — see each section below.

---

## Claude Code

Claude Code emits OpenTelemetry signals natively when the telemetry env vars are set. Cost, token usage, sessions, commits, lines of code, and tool decisions show up in the **Claude Code Metrics** dashboard.

### Setup

Add to your shell profile (`~/.bashrc`, `~/.zshrc`, or a sourced env file):

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1

export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_LOGS_INCLUDE_USER_PROMPTS=1     # optional: include user prompts in logs

export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<COLLECTOR_HOST>:4318

# Required — the collector rejects unauthenticated pushes with HTTP 401.
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <OTEL_AUTH_TOKEN>"
```

Use `127.0.0.1` for `<COLLECTOR_HOST>` if Claude Code runs on the collector machine; otherwise its LAN IP/hostname.
Start a fresh terminal so the env vars are picked up, then run Claude Code as usual.

### Optional resource attributes

To attach repo / project context to every signal:

```bash
export OTEL_RESOURCE_ATTRIBUTES="service.name=claude-code,deployment.environment=local,git.repo=$(git rev-parse --show-toplevel 2>/dev/null | xargs -I{} basename {})"
```

The collector strips high-cardinality keys (`host.arch`, `os.type`, `host.name`, `process.pid`) before
remote-write to Prometheus, so you can pass freely without inflating series count. `session_id` is intentionally
kept as a label because dashboards rely on it for per-session breakdowns.

### Verify

```bash
# 1. Run any short Claude Code interaction so it emits at least one metric

# 2. Confirm metric points are being accepted at the collector
curl -s 'http://127.0.0.1:9090/api/v1/query?query=rate(otelcol_receiver_accepted_metric_points_total[1m])' | jq .

# 3. Confirm the cost counter has data
curl -s 'http://127.0.0.1:9090/api/v1/query?query=sum(claude_code_cost_usage_USD_total)' | jq .
```

Open the Claude Code dashboard at http://localhost:3002 (folder *Agents*) — within ~30s of a session ending the cost / token tiles update.

---

## OpenCode

OpenCode does not emit OTel natively. The official path is [`@devtheops/opencode-plugin-otel`](https://github.com/DEVtheOPS/opencode-plugin-otel), which mirrors the same metric surface as Claude Code.

### Install the plugin

Edit `~/.config/opencode/opencode.json` and add the plugin to the `plugin` array:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "@devtheops/opencode-plugin-otel@latest"
  ]
}
```

OpenCode auto-installs the plugin from npm on next start.

### Configure the sender

Drop these into `~/.config/opencode/otel.env` (or your shell profile):

```bash
export OPENCODE_ENABLE_TELEMETRY=1
export OPENCODE_OTLP_ENDPOINT="http://<COLLECTOR_HOST>:4318"
export OPENCODE_OTLP_PROTOCOL="http/protobuf"
export OPENCODE_OTLP_HEADERS="Authorization=Bearer <OTEL_AUTH_TOKEN>"   # required
export OPENCODE_RESOURCE_ATTRIBUTES="service.name=opencode,deployment.environment=local"
```

Source it before launching opencode:

```bash
source ~/.config/opencode/otel.env
opencode
```

### Optional knobs

The plugin exposes more env vars; the defaults are sensible but useful to know:

| Variable | Default | What it does |
|---|---|---|
| `OPENCODE_OTLP_METRICS_INTERVAL` | `60000` (60s) | Push interval for metrics in ms |
| `OPENCODE_OTLP_LOGS_INTERVAL` | `5000` (5s) | Push interval for log records in ms |
| `OPENCODE_OTLP_METRICS_TEMPORALITY` | (unset) | Set to `delta` if your backend expects delta temporality. This stack's collector does delta→cumulative conversion, so leave unset. |
| `OPENCODE_DISABLE_METRICS` | (unset) | Comma-separated metric names to skip |
| `OPENCODE_DISABLE_TRACES` | (unset) | Comma-separated span names to skip |
| `OPENCODE_METRIC_PREFIX` | `opencode.` | Prefix prepended to every metric name |
| `OPENCODE_OTLP_HEADERS` | (unset) | **Required** here — carries `Authorization=Bearer <OTEL_AUTH_TOKEN>` (set above) |

### Verify

```bash
# Metric should appear within ~60s of the first OpenCode message
curl -s 'http://127.0.0.1:9090/api/v1/query?query=sum(opencode_message_count_total)' | jq .
```

Dashboard: **OpenCode Metrics** (folder *Agents*).

---

## Hermes

Hermes ships telemetry through a first-party plugin **[`hermes-otel-exporter`](https://github.com/yw0nam/hermes-otel-exporter)** (installed at `~/.hermes/plugins/hermes-otel-exporter/`). It hooks into 13 lifecycle events (`on_session_start`, `pre_llm_call`, `post_llm_call`, `pre_tool_call`, `post_tool_call`, `pre_approval_request`, `post_approval_response`, `pre_gateway_dispatch`, `subagent_stop`, `transform_tool_result`, etc.) and pushes OTLP via gRPC to the collector.

The plugin **fails open** — if the OTel Python SDK is missing or the collector is unreachable, the hooks no-op silently and Hermes keeps running. This is important for headless agent loops where telemetry must never block the request path.

### Install the OTLP SDK (one-time, system Python)

```bash
pip install opentelemetry-api opentelemetry-sdk \
            opentelemetry-exporter-otlp-proto-grpc
```

### Enable the plugin

```bash
hermes plugins enable hermes-otel-exporter
```

(Optionally check it with `hermes plugins list`.)

### Configure the sender

Defaults already match this stack (gRPC, `127.0.0.1:4317`, insecure). The plugin reads these env vars at startup:

| Var | Default | Purpose |
|---|---|---|
| `HERMES_OTEL_ENDPOINT` | `127.0.0.1:4317` | OTLP gRPC endpoint |
| `HERMES_OTEL_SERVICE` | `hermes-agent` | `service.name` resource attribute (also used as the Loki `service_name` label) |
| `HERMES_OTEL_ENV` | `local` | `deployment.environment` resource attribute |
| `HERMES_OTEL_INSECURE` | `true` | Disable TLS for the local collector |
| `HERMES_OTEL_DEBUG` | `false` | Verbose plugin logging — turn on if metrics aren't showing up |
| `HERMES_OTEL_SESSION_LABEL` | `false` | Add `session_id` as a metric label. Off by default to avoid per-session series fanout (Hermes does *not* have the same cardinality leak as Claude Code / OpenCode and is well-behaved on this front). |

If you run Hermes from a container in the same compose network, repoint the endpoint:

```bash
export HERMES_OTEL_ENDPOINT=obs-otel-collector:4317
```

Note the **gRPC port (4317)** — unlike OpenCode which is wired to HTTP/protobuf (4318), this plugin uses gRPC.

#### Bearer token (required)

The plugin has no auth env var of its own, but it builds the OTLP exporter **without an explicit
`headers=` argument** (`runtime_core.py`), so the OpenTelemetry Python SDK falls back to the standard
env var. Set it and the token rides along as gRPC metadata:

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <OTEL_AUTH_TOKEN>"
```

This is required even for a local Hermes on the same host — auth is enforced on the gRPC receiver too,
so without it the plugin's exports get `UNAUTHENTICATED` and silently fail open (Hermes keeps running,
no metrics appear). For a remote Hermes also point `HERMES_OTEL_ENDPOINT=<COLLECTOR_HOST>:4317`.

### Emitted metrics

| Metric (OTel name) | Prometheus name | Type | Labels |
|---|---|---|---|
| `hermes.session.count` | `hermes_session_count_total` | counter | `platform` |
| `hermes.session.duration` | `hermes_session_duration_milliseconds_*` | histogram | `platform` |
| `hermes.llm.calls` | `hermes_llm_calls_total` | counter | `model`, `provider`, `api_mode` |
| `hermes.llm.duration` | `hermes_llm_duration_milliseconds_*` | histogram | same as above |
| `hermes.token.usage` | `hermes_token_usage_tokens_total` | counter | `model`, `provider`, `type` (`input` / `output` / `cache_read` / `cache_write` / `reasoning`) |
| `hermes.cost.usage` | `hermes_cost_usage_USD_total` | counter | `model`, `provider` |
| `hermes.tool.calls` | `hermes_tool_calls_total` | counter | `tool_name`, `success` |
| `hermes.tool.duration` | `hermes_tool_duration_milliseconds_*` | histogram | `tool_name`, `success` |
| `hermes.errors` | `hermes_errors_total` | counter | `component`, `tool_name` |

Logs are emitted alongside metrics — accessible in Loki via `{service_name="hermes-agent"}`.

### Verify

```bash
# 1. Run any short Hermes session

# 2. Confirm session counter advanced
curl -s 'http://127.0.0.1:9090/api/v1/query?query=sum(hermes_session_count_total)' | jq .

# 3. Confirm logs landed in Loki
curl -sG 'http://127.0.0.1:3110/loki/api/v1/query_range' \
  --data-urlencode 'query={service_name="hermes-agent"}' | jq '.data.result | length'

# 4. Sanity-check plugin is actually loaded
hermes plugins list | grep otel
```

Dashboard: **Hermes Agent Metrics** (folder *Agents*).

### Disable

```bash
hermes plugins disable hermes-otel-exporter
```

---

## End-to-end checklist

After wiring an agent, walk down this list:

1. **Collector reachable** — `curl -fsS http://127.0.0.1:13133` returns 200.
2. **Receiver accepting** — `rate(otelcol_receiver_accepted_metric_points_total[1m]) > 0`.
3. **Exporter not failing** —
   ```promql
   rate(otelcol_exporter_send_failed_metric_points_total[5m])
   ```
   should stay at 0. If it climbs, check `docker logs obs-otel-collector` for the exporter name and root cause.
4. **Metric is queryable** — the agent-specific cost / count counter returns a non-zero `last_over_time` result.
5. **Dashboard renders** — at least one panel in the agent's dashboard shows data within the timepicker range.

The **Observability — Cardinality & Stack Health** dashboard (folder *Agents*) covers steps 2–3 visually; bookmark it.

---

## Troubleshooting

### "No data" in panels even though the agent is running

Most common causes:

- **Env vars not loaded** — `CLAUDE_CODE_ENABLE_TELEMETRY` / `OPENCODE_ENABLE_TELEMETRY` must be `1`, not just exported empty. Confirm with `env | grep -iE 'TELEMETRY|OTLP|OTEL'` in the same shell that launched the agent.
- **Wrong endpoint/protocol pair** — gRPC must use port 4317, HTTP/protobuf must use 4318. Mixing them fails silently with `connection refused` or `unsupported protocol`.
- **Push interval longer than your dashboard window** — `last_over_time(M[5m])` is empty if the agent only pushed once in that window. Widen the window (the dashboards default to `1h` or `$__range` for this reason).
- **Time range mismatch** — Grafana timepicker has to overlap the period the agent was actually running. Check the *Active Time* tile on the agent's dashboard to see when it was last alive.

### Cache Hit Ratio / other ratios look like they dip to 0

This is the rate-window-sparsity issue. The fix in this repo is to use cumulative within-window growth (`last_over_time - min_over_time`) instead of `rate()` for ratios. If you add a new ratio panel, prefer:

```promql
sum(last_over_time(numerator_total[1h]) - min_over_time(numerator_total[1h]))
  / sum(last_over_time(denominator_total[1h]) - min_over_time(denominator_total[1h]))
```

over

```promql
sum(rate(numerator_total[5m])) / sum(rate(denominator_total[5m]))
```

`rate()` requires ≥ 2 samples in the window per series; with push intervals of 60s the window has to be at least 2–3× that to be stable. The cumulative form has no such constraint.

### A panel shows a phantom series with empty label and value = 0

That means the query uses `... or vector(0)` and PromQL's `or` operator added a labelless `{}` group to the by-label output. For aggregations that already split by a label, drop the `or vector(0)` fallback — let the panel show "no data" when there genuinely is none. Keep `or vector(0)` only on scalar gauges where a 0 reading is more intuitive than an empty panel.

### "increase[$__range]" reports a number that is way too high

`increase()` extrapolates across counter resets, and the OTel `deltatocumulative` processor resets per-session series whenever they go idle for more than 5 minutes. Across many sessions this compounds. Use this instead:

```promql
sum(last_over_time(metric[$__range]) - min_over_time(metric[$__range])) by (label)
```

See the *Accurate metric queries* section in the [top-level README](../README.md) for the full story (it took us a couple of passes to land on this pattern).

### Cardinality keeps creeping up

The **Observability — Cardinality & Stack Health** dashboard surfaces this. Common offenders:

- A new label leaks in from an agent's resource attributes — add it to `transform/strip_metric_cardinality` (datapoint context) or `resource/strip_metric_cardinality` (resource context) in `otel-collector-config.yaml`.
- A buggy plugin emits an ever-changing label (timestamp, random ID). Disable the metric via the relevant `OPENCODE_DISABLE_METRICS` / equivalent env, or strip the label in the collector.

`session_id` is intentionally retained as a per-series identifier because dashboards rely on it. The PromQL patterns described above (`last - min`, `count by (session_id) (max_over_time(...))`) are designed to work *with* that cardinality rather than against it.
