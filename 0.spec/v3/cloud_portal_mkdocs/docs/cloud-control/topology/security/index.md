# Security Topology

## Firewall Rules

| VM | Ports Open | Protocol |
|----|------------|----------|
| oci-f-micro_1 | 22, 25, 587, 993 | TCP |
| oci-f-micro_2 | 22, 80, 443 | TCP |
| gcp-f-micro_1 | 22, 80, 443 | TCP |
| oci-p-flex_1 | 22, 80, 443 | TCP |

## Security Layers

1. Cloud Firewall (Oracle/GCP)
2. UFW Host Firewall
3. NPM Reverse Proxy
4. Authelia 2FA
5. Docker Network Isolation
