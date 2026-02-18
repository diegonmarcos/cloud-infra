# Cloud Infrastructure Monitor

> **Version**: 1.0.0
> **Generated**: 2025-12-23 16:06
> **Last Data Update**: Never
> **Updated By**: N/A
> **Source**: `cloud_monitor.json`

This document is auto-generated from `cloud_monitor.json` using `cloud_json_export.py`.
Do not edit manually - changes will be overwritten.

---


## Summary

| Metric             | Value |
| ------------------ | ----- |
| Total VMs          | 4     |
| VMs Online         | -     |
| Total Endpoints    | 6     |
| Endpoints Healthy  | -     |
| Total Containers   | -     |
| Containers Running | -     |
| Last Full Check    | -     |

### SSL Certificates Expiring Soon

*None*

## VM Status

| VM            | IP              | Pingable | SSH | Latency (ms) | Uptime | Last Check |
| ------------- | --------------- | -------- | --- | ------------ | ------ | ---------- |
| oci-f-micro_1 | 130.110.251.193 | -        | -   | -            | -      | -          |
| oci-f-micro_2 | 129.151.228.66  | -        | -   | -            | -      | -          |
| gcp-f-micro_1 | 34.55.55.234    | -        | -   | -            | -      | -          |
| oci-p-flex_1  | 84.235.234.87   | -        | -   | -            | -      | -          |

### VM Resources

| VM            | Load Avg | Memory % | Disk % |
| ------------- | -------- | -------- | ------ |
| oci-f-micro_1 | -        | -        | -      |
| oci-f-micro_2 | -        | -        | -      |
| gcp-f-micro_1 | -        | -        | -      |
| oci-p-flex_1  | -        | -        | -      |

### Wake-on-Demand Status

| VM           | Awake | Last Wake | Last Sleep | Wake Reason |
| ------------ | ----- | --------- | ---------- | ----------- |
| oci-p-flex_1 | -     | -         | -          | -           |

## Endpoint Status

| Domain                      | HTTP | Latency (ms) | SSL Valid | SSL Expiry | WoD | Last Check |
| --------------------------- | ---- | ------------ | --------- | ---------- | --- | ---------- |
| analytics.diegonmarcos.com  | -    | -            | -         | -          | No  | -          |
| mail.diegonmarcos.com       | -    | -            | -         | -          | No  | -          |
| proxy.diegonmarcos.com      | -    | -            | -         | -          | No  | -          |
| auth.diegonmarcos.com       | -    | -            | -         | -          | No  | -          |
| photos.app.diegonmarcos.com | -    | -            | -         | -          | Yes | -          |
| cal.diegonmarcos.com        | -    | -            | -         | -          | Yes | -          |

## Container Status

### All Containers

| VM            | Container      | Running | Restarts | Memory (MB) | CPU % |
| ------------- | -------------- | ------- | -------- | ----------- | ----- |
| oci-f-micro_1 | mailu-front    | -       | -        | -           | -     |
| oci-f-micro_1 | mailu-admin    | -       | -        | -           | -     |
| oci-f-micro_1 | mailu-imap     | -       | -        | -           | -     |
| oci-f-micro_1 | mailu-smtp     | -       | -        | -           | -     |
| oci-f-micro_1 | mailu-antispam | -       | -        | -           | -     |
| oci-f-micro_1 | mailu-redis    | -       | -        | -           | -     |
| oci-f-micro_2 | matomo-app     | -       | -        | -           | -     |
| oci-f-micro_2 | matomo-db      | -       | -        | -           | -     |
| gcp-f-micro_1 | npm            | -       | -        | -           | -     |
| gcp-f-micro_1 | authelia       | -       | -        | -           | -     |
| gcp-f-micro_1 | flask-api      | -       | -        | -           | -     |
| oci-p-flex_1  | photoprism     | -       | -        | -           | -     |
| oci-p-flex_1  | photoprism-db  | -       | -        | -           | -     |
| oci-p-flex_1  | radicale       | -       | -        | -           | -     |

### oci-f-micro_1 Containers

| Container      | Running | Restarts | Memory (MB) | CPU % |
| -------------- | ------- | -------- | ----------- | ----- |
| mailu-front    | -       | -        | -           | -     |
| mailu-admin    | -       | -        | -           | -     |
| mailu-imap     | -       | -        | -           | -     |
| mailu-smtp     | -       | -        | -           | -     |
| mailu-antispam | -       | -        | -           | -     |
| mailu-redis    | -       | -        | -           | -     |

### oci-f-micro_2 Containers

| Container  | Running | Restarts | Memory (MB) | CPU % |
| ---------- | ------- | -------- | ----------- | ----- |
| matomo-app | -       | -        | -           | -     |
| matomo-db  | -       | -        | -           | -     |

### gcp-f-micro_1 Containers

| Container | Running | Restarts | Memory (MB) | CPU % |
| --------- | ------- | -------- | ----------- | ----- |
| npm       | -       | -        | -           | -     |
| authelia  | -       | -        | -           | -     |
| flask-api | -       | -        | -           | -     |

### oci-p-flex_1 Containers

| Container     | Running | Restarts | Memory (MB) | CPU % |
| ------------- | ------- | -------- | ----------- | ----- |
| photoprism    | -       | -        | -           | -     |
| photoprism-db | -       | -        | -           | -     |
| radicale      | -       | -        | -           | -     |

## Alerts

*No active alerts*
