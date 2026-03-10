# nosana-telemetry

OpenTelemetry-based monitoring for Nosana GPU node hosts. Collects logs and metrics from 1300+ distributed Nosana nodes and centralizes them into a Grafana dashboard. Push-based architecture — no VPN or mesh network required.

## Architecture

```
+---------------------------+          OTLP/HTTP + Bearer Token          +---------------------------+
|       NOSANA HOST         |  ─────────────────────────────────────►    |      CENTRAL SERVER       |
|                           |              (push-based)                  |                           |
|  Docker                   |                                            |  OTel Collector (gateway) |
|  └─ Podman (nested)      |                                            |  ├─ Grafana Loki  (logs)  |
|     ├─ nosana-node        |                                            |  ├─ Prometheus  (metrics) |
|     ├─ frpc               |                                            |  └─ Grafana  (dashboards) |
|     └─ job containers     |                                            |                           |
|                           |                                            |  Ports:                   |
|  OTel Collector (client)  |                                            |   3000  Grafana UI        |
|  ├─ Tails container logs  |                                            |   3100  Loki API          |
|  ├─ Strips ANSI codes     |                                            |   4317  OTLP gRPC         |
|  └─ Filters spinner noise |                                            |   4318  OTLP HTTP         |
|                           |                                            |   9090  Prometheus        |
+---------------------------+          x1300+ nodes                      +---------------------------+
```

All components run as Docker containers. Zero packages are installed on the host OS.

## Quick Start

### Server

```bash
bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/server/install.sh)
```

The installer prompts for an API key and Grafana admin password, then brings up the full stack.

### Client

```bash
bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/client/install.sh) <server_address> <api_key>
```

Replace `<server_address>` with the server's public IP or hostname and `<api_key>` with the token configured on the server.

## What Gets Collected

### Logs

| Source | Description |
|---|---|
| nosana-node | Core Nosana node process logs |
| frpc | FRP client tunnel logs |
| Job containers | Logs from GPU job workloads |

All logs are cleaned of noise before transmission (see [Log Cleaning Pipeline](#log-cleaning-pipeline)).

### Metrics

- CPU utilization
- Memory usage
- Disk I/O
- Network throughput
- System load averages

## Log Cleaning Pipeline

Raw container logs pass through a multi-stage pipeline before leaving the host:

```
Raw container log
  │
  ▼
k8s-file parser ──── Extract timestamp from container log format
  │
  ▼
ANSI stripper ─────── Remove color codes, cursor movement sequences
  │
  ▼
Noise filter ──────── Drop spinner frames, status spam, empty lines
  │
  ▼
Host labeling ─────── Attach node hostname as resource attribute
  │
  ▼
Batch processor ───── Buffer and compress for efficient transmission
  │
  ▼
OTLP/HTTP push ────── Send to central server with bearer token auth
```

### What Gets Filtered Out

- **ANSI escape codes** -- colors, cursor movement, formatting sequences
- **Ora spinner frames** -- the animated characters: `(...)`
- **"RUNNING JOB...Duration:"** status updates (thousands per minute)
- **"RESTARTING...In X seconds"** countdown frames
- **"Installing @nosana"** spinner frames
- **Empty lines**

## Configuration

### Server

Config file: `/opt/nosana-telemetry/.env`

| Variable | Description |
|---|---|
| `API_KEY` | Bearer token for client authentication |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin UI password |

### Client

Config file: `/opt/nosana-telemetry/.env`

| Variable | Description |
|---|---|
| `SERVER_ADDRESS` | Central server IP or hostname |
| `API_KEY` | Bearer token (must match server) |
| `NODE_NAME` | Identifier for this host in dashboards |

### Retention

Default retention is 48 hours. To adjust:

- **Logs:** Edit `loki-config.yaml` -- modify `retention_period`
- **Metrics:** Edit `prometheus.yml` -- modify `storage.tsdb.retention.time`

## Stack Components

| Component | Version |
|---|---|
| OpenTelemetry Collector Contrib | 0.120.0 |
| Grafana Loki | 3.4.2 |
| Prometheus | v3.2.1 |
| Grafana | 11.5.2 |

## Troubleshooting

### Client cannot connect to server

1. Verify the server address is correct in `/opt/nosana-telemetry/.env`.
2. Confirm ports 4317 and 4318 are open on the server firewall.
3. Check that the API key matches between client and server configs.
4. Test connectivity: `curl -v http://<server_address>:4318/v1/logs`

### No logs appearing in Grafana

1. Confirm the Nosana podman container is running: `docker ps`
2. Check OTel Collector logs on the client: `docker logs otel-collector`
3. Verify the podman volume is accessible to the collector container.
4. On the server, check Loki is receiving data: `curl http://localhost:3100/ready`

### Container permission errors

The OTel Collector needs read access to the podman container log volume. If logs are not flowing:

1. Check volume mount paths in `docker-compose.yml`.
2. Ensure the log directory exists and is readable by the collector container.
3. Restart the collector: `docker compose restart otel-collector`

### Verifying the full pipeline

```bash
# Server: check all services are healthy
docker compose ps

# Server: query Loki directly
curl -G 'http://localhost:3100/loki/api/v1/labels'

# Client: check collector status
docker logs --tail 50 otel-collector
```

## Updating

To update configuration on an existing installation:

1. Edit the relevant files in `/opt/nosana-telemetry/`.
2. Restart the stack: `cd /opt/nosana-telemetry && docker compose down && docker compose up -d`

To update to the latest version, re-run the install script. It will pull updated configs and restart services.

**Server:**
```bash
bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/server/install.sh)
```

**Client:**
```bash
bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/client/install.sh) <server_address> <api_key>
```

## License

MIT
