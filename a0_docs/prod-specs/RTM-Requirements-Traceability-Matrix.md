# RTM — Requirements Traceability Matrix

> Cloud Infrastructure as Code — Diego Nepomuceno Marcos

---

## Traceability: Business Req → Product Req → Service → Test

| BRD Req | PRD Story | Service(s) | VM | Test |
|---------|-----------|------------|-----|------|
| Digital Sovereignty | COM-01, COM-02 | Maddy, SnappyMail, SMTP Proxy | oci-mail | Email send/receive |
| Digital Sovereignty | PRD-01 | HedgeDoc, Etherpad | oci-apps | Doc create/edit |
| Digital Sovereignty | PRD-02 | Grist | oci-apps | Sheet CRUD |
| Digital Sovereignty | PRD-03 | Radicale | oci-apps | CalDAV sync |
| Digital Sovereignty | PRD-04 | FileBrowser | oci-apps | File upload/download |
| Digital Sovereignty | PRD-05 | Vaultwarden | oci-apps | Password sync |
| Digital Sovereignty | MED-01 | PhotoPrism | oci-apps | Photo upload + AI classify |
| Digital Sovereignty | MED-02 | Matomo, Umami | oci-analytics | Page tracking |
| Zero Cost | All | All 59 services | All 5 VMs | $0 monthly bill |
| Single-Operator | OPS-01 | Build Engine | — | `build.sh ship` completes |
| Single-Operator | OPS-02 | Dozzle, LGTM | oci-analytics, oci-apps | Dashboard loads |
| Single-Operator | OPS-03 | Sauron Central | oci-apps | Logs aggregated |
| Single-Operator | OPS-04 | Backup Borg/Bup, DB Agent | oci-apps, all | Backup completes |
| Single-Operator | OPS-05 | Watchdog, Container-Init | all VMs | Auto-recovery after kill |
| Security | — | Authelia, Caddy, Introspect Proxy | gcp-proxy | 2FA enforced |
| Security | — | SOPS, secrets.yaml | all services | No plaintext in git |
| Security | — | WireGuard | all VMs | Mesh connectivity |
| Security | — | Sauron Lite | all VMs | File integrity check |
| AI Automation | AI-01 | Ollama, Rig Agentic | oci-apps, gcp-t4 | Model inference |
| AI Automation | AI-02 | C3 MCP, Cloud CGC MCP | oci-apps | MCP tool response |
| AI Automation | AI-03 | KG Graph | oci-apps | Graph query |
| AI Automation | AI-04 | Google Workspace MCP | oci-apps | Gmail/Calendar access |
| AI Automation | AI-05 | Mail MCP | oci-apps | Email read/send |
| Development | DEV-01 | Code Server | oci-apps | IDE loads |
| Development | DEV-02 | Gitea | oci-apps | Git push/pull |
| Development | DEV-03 | DBGate | oci-apps | DB query execution |
| Development | DEV-04 | Dagu | oci-analytics | Workflow execution |
| Development | DEV-05 | Crawlee Cloud | oci-apps | Scrape job completes |
| Development | DEV-06 | Quant Lab | oci-apps | Notebook execution |
