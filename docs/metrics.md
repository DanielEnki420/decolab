# Decolab's own metrics

Decolab's scripts write their measurements as `.prom` files to
`/var/lib/node_exporter`; node_exporter's textfile collector serves them to
Prometheus. Every metric is prefixed `decolab_`. Alert rules
(`config/prometheus/rules.yml`) and dashboards (`config/perses/provisioning`)
use only the names listed here; `tests/test-configs.sh` checks that.

A writer replaces its file atomically (write to a temporary file in the same
directory, then rename), so node_exporter never reads half a file. The rule
`TextfileMetricStale` notices a writer that stopped.

| File | Written by | Interval | Metrics |
|---|---|---|---|
| `fan.prom` | fan control service | 5 s | `decolab_fan_rpm`, `decolab_fan_pwm`, `decolab_fan_failsafe_active`, `decolab_fan_night_mode_active`, `decolab_fan_pwm_write_errors_total`, `decolab_fan_sensor_ok`, `decolab_soc_power_watts`, `decolab_soc_energy_kwh_total` |
| `services.prom` | `check-services.sh` | 15 min | `decolab_systemd_units_failed`, `decolab_systemd_units_restart_loop` |
| `cadvisor.prom` | `check-cadvisor-coverage.sh` | 15 min | `decolab_docker_containers_running` |
| `tailscale.prom` | `check-tailscale-keys.sh` | daily | `decolab_tailscale_keys_expiring`, `decolab_tailscale_key_days_left` |
| `speedtest.prom` | `speedtest.sh` | 6 h | `decolab_speedtest_download_mbit`, `decolab_speedtest_upload_mbit`, `decolab_speedtest_ping_ms`, `decolab_speedtest_jitter_ms`, `decolab_speedtest_last_success_timestamp_seconds`, `decolab_speedtest_last_run_timestamp_seconds`, `decolab_speedtest_last_run_ok` |
| `ups.prom` | `ups-metrics.sh` | 1 min | `decolab_ups_reachable`, `decolab_ups_on_line`, `decolab_ups_on_battery`, `decolab_ups_charging`, `decolab_ups_battery_low`, `decolab_ups_battery_percent`, `decolab_ups_runtime_seconds`, `decolab_ups_load_percent`, `decolab_ups_output_volts`, `decolab_ups_replace_battery`, `decolab_ups_shutdown_battery_percent`, `decolab_ups_shutdown_runtime_seconds` |

Names follow the Prometheus conventions: base units (`_seconds`,
`_percent`), `_total` for counters, `1`/`0` for yes/no.
