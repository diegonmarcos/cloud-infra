# Operations (spec_ops.md)

This document provides instructions on how to run and manage the n8n application.

## Accessing the n8n GUI (KDE)

You can access the n8n web interface from any modern web browser on your KDE desktop (e.g., Firefox, Google Chrome).

1.  **Get the External IP Address:**
    Open a terminal (like Konsole) and run the following command:
    ```bash
    gcloud compute instances describe n8n-vm --zone us-east1-b --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
    ```
2.  **Access n8n:**
    Open your web browser and navigate to the following URL, replacing `[EXTERNAL_IP]` with the IP address from the previous step:
    ```
    http://[EXTERNAL_IP]:5678
    ```

## Managing n8n from the CLI

You can manage the n8n application and the VM from the command line using Konsole on your KDE desktop.

### Managing the n8n Container

1.  **SSH into the VM:**
    ```bash
    gcloud compute ssh n8n-vm --zone us-east1-b
    ```
2.  **Manage the n8n service:**
    Once you are logged into the VM, you can use the following `docker compose` commands:

    -   **Check the status of n8n:**
        ```bash
        docker compose ps
        ```
    -   **Stop n8n:**
        ```bash
        docker compose stop
        ```
    -   **Start n8n:**
        ```bash
        docker compose start
        ```
    -   **View n8n logs:**
        ```bash
        docker compose logs -f
        ```

### Managing the VM

You can manage the VM itself from your local terminal:

-   **Stop the VM:**
    ```bash
    gcloud compute instances stop n8n-vm --zone us-east1-b
    ```
-   **Start the VM:**
    ```bash
    gcloud compute instances start n8n-vm --zone us-east1-b
    ```

## Managing the VM from the GUI (Google Cloud Console)

You can also manage your VM through the Google Cloud Console, a web-based GUI.

1.  **Open the Google Cloud Console:**
    Navigate to [https://console.cloud.google.com/](https://console.cloud.google.com/).
2.  **Go to VM instances:**
    In the console, navigate to **Compute Engine** > **VM instances** to see and manage your `n8n-vm` instance.
