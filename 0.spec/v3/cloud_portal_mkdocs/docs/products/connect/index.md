# Connect

Infrastructure access methods.

## SSH Access

| VM | Command |
|----|---------|
| oci-f-micro_1 | `ssh -i ~/.ssh/id_rsa ubuntu@130.110.251.193` |
| oci-f-micro_2 | `ssh -i ~/.ssh/id_rsa ubuntu@129.151.228.66` |
| gcp-f-micro_1 | `gcloud compute ssh arch-1 --zone us-central1-a` |
| oci-p-flex_1 | `ssh -i ~/.ssh/id_rsa ubuntu@84.235.234.87` |

## API Endpoints

| Service | Endpoint | Auth |
|---------|----------|------|
| NPM API | proxy.diegonmarcos.com/api | JWT |
| Matomo API | analytics.diegonmarcos.com/api | Token |
| Mail API | mail.diegonmarcos.com/api | Basic |

## CLI Tools

| Provider | Tool | Config |
|----------|------|--------|
| Oracle | `oci` | ~/.oci/config |
| GCloud | `gcloud` | ~/.config/gcloud |
| GitHub | `gh` | ~/.config/gh |
