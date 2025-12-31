Certainly\! To ensure your **e2-micro** VM falls under the **Compute Engine Free Tier** in the US East location, you must specify the correct region.

The eligible US East region for the free tier is **South Carolina (`us-east1`)**. You must also specify a valid zone within that region, such as `us-east1-b`.

Here is the `gcloud` command you should use:

-----

## 💻 CLI Command for US East Free Tier VM

Use the following command, replacing `[INSTANCE_NAME]` with your desired name:

```bash
gcloud compute instances create [INSTANCE_NAME] \
  --zone=us-east1-b \
  --machine-type=e2-micro \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=30GB \
  --network-tier=STANDARD
```

### Key Parameters for Free Tier Compliance

| Parameter | Value | Reason for Free Tier (US East) |
| :--- | :--- | :--- |
| **`--zone`** | `us-east1-b` | This zone is part of the **South Carolina (`us-east1`)** region, which is one of the three US regions eligible for the free tier. |
| **`--machine-type`** | `e2-micro` | This is the specific shared-core machine type that provides the equivalent of **730 hours** of usage per month (free). |
| **`--boot-disk-size`** | `30GB` | Limits the disk size to **30 GiB** of **Standard Persistent Disk**, which is the free tier maximum for disk storage. |
| **`--image-project` / `--image-family`** | `debian-cloud` | Confirms the use of a free-to-use Linux operating system (like Debian or Ubuntu). |

By using these specific parameters, you ensure your instance is provisioned in a Free Tier-eligible US East zone with the correct configuration. 💸