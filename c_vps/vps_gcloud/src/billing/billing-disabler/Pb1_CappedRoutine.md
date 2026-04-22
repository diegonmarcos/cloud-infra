Here is how you can create an automated workflow in Google Cloud to cap spending, send an email, and disable a specific service like an AI API when a budget threshold is reached.

This process isn't a single "routine" but rather a powerful workflow connecting three Google Cloud services:

1.  **Cloud Billing Budgets:** To monitor spending and send alerts.
2.  **Pub/Sub:** A messaging service to receive the budget alert programmatically.
3.  **Cloud Functions:** A serverless function (your "routine") that listens to the alert and performs the actions.

-----

### 🗺️ The Overall Workflow

Here is the high-level plan:

1.  **Budget Creation:** You create a **Cloud Billing Budget** for your project.
2.  **Alert Setup:** You configure this budget to:
      * **Send an email** to billing administrators (handles your email requirement).
      * **Publish a message** to a **Pub/Sub topic** when your spend (e.g., 100% of your target) is reached.
3.  **Function Trigger:** You create a **Cloud Function** that is automatically triggered whenever a new message appears on that Pub/Sub topic.
4.  **Action Execution:** The Cloud Function's code runs, parses the budget message, and then calls the **Service Usage API** to disable your specified AI service (e.g., the Vertex AI API).

-----

### 🛠️ Step-by-Step Implementation Guide

Follow these steps to build your automated control system.

#### Step 1: Create the Pub/Sub Topic

This is the "mailbox" where your budget will send its automated alert.

1.  Go to the **Pub/Sub** console in Google Cloud.
2.  Click **Create Topic**.
3.  Give it a **Topic ID** (e.g., `budget-disable-trigger`) and create it.
4.  **Important:** You must give Google Cloud's billing service permission to publish to this topic.
      * Go to the **IAM & Admin** console.
      * Find the service account that looks like `cloud-billing-alerts@g.co`. If it's not there, you may need to find the **Billing Account service account**, which looks like `biller-PROJECT_NUMBER@gcp-sa-billing.iam.gserviceaccount.com`.
      * Click the pencil icon and grant it the **`Pub/Sub Publisher`** role. (Alternatively, go to your new Pub/Sub topic, click Permissions, and add this service account with the `Pub/Sub Publisher` role).

#### Step 2: Create the Cloud Billing Budget

1.  Go to the **Billing** console.
2.  Select **Budgets & alerts**.
3.  Click **Create budget**.
4.  **Name** your budget (e.g., `daily-ai-cap`).
5.  **Scope:** Select your project.
6.  **Amount:**
      * **Budget type:** Select **Specified amount**.
      * **Target amount:** Enter your desired cap (e.g., `€50`).
      * **Time period:** While you can't set a *true* daily budget, you can set a **Monthly** budget and have it alert you based on daily spend. A common approach is to set a monthly budget (e.g., `€1500` for a €50/day goal) and use the alerts to manage it.
7.  **Actions:** This is the most critical part.
      * **Alert threshold rules:** Set an alert for **100%** of **Actual spend**. This will fire when your spend hits the `€50` target.
      * **Manage notifications:**
          * ✅ Check **Email alerts to billing administrators** (This handles your email requirement).
          * ✅ Check **Connect a Pub/Sub topic** and select the `budget-disable-trigger` topic you created in Step 1.

#### Step 3: Create the Cloud Function

This function is your automated "routine" that will perform the action.

1.  Go to the **Cloud Functions** console.
2.  Click **Create function** (use 2nd gen if available).
3.  **Name** your function (e.g., `api-disabler-from-budget`).
4.  **Trigger:**
      * **Trigger type:** Select **Cloud Pub/Sub**.
      * **Pub/Sub topic:** Select the `budget-disable-trigger` topic.
5.  **Runtime & Service Account:**
      * Under **Runtime, build and connections settings**, click the **Runtime** tab.
      * **Service account:** This is crucial. The function needs permission to disable other services.
          * Click **Create a new service account**.
          * Name it (e.g., `api-disabler-sa`).
          * Grant this new service account the role: **`Service Usage Admin`** (`roles/serviceusage.serviceUsageAdmin`).
          * Select this new service account for your function.
6.  **Code:**
      * Select your preferred runtime (e.g., **Python**).
      * In the `main.py` file, use the code below.
      * In the `requirements.txt` file, add:
        ```
        google-cloud-service-usage
        ```

-----

### 🐍 Example Code (Python)

Paste this into the `main.py` tab of your Cloud Function.

**Remember to change `YOUR_PROJECT_ID` and `API_TO_DISABLE`\!**

```python
import base64
import json
from google.api_core import exceptions
from google.cloud import serviceusage_v1

# --- Configuration ---
# TODO: Change these values
PROJECT_ID = "your-gcp-project-id"
API_TO_DISABLE = "aiplatform.googleapis.com" # Example: Vertex AI
# You might want to disable:
# "language.googleapis.com" (Natural Language API)
# "vision.googleapis.com" (Vision API)
# ---------------------

def disable_specific_api(event, context):
    """
    Triggered by a Pub/Sub message from a Cloud Billing Budget.
    Disables a specified API.
    """
    print(f"Function triggered by messageId: {context.message_id}")

    # 1. Parse the budget notification
    try:
        pubsub_data = base64.b64decode(event["data"]).decode("utf-8")
        notification = json.loads(pubsub_data)
        cost_amount = notification.get("costAmount", 0)
        budget_amount = notification.get("budgetAmount", 0)

        print(f"Budget notification received: Cost {cost_amount} has met/exceeded budget {budget_amount}.")
        
        # Optional: Add logic to only fire if cost is above a certain amount
        if cost_amount < budget_amount:
            print("Cost is below budget. No action taken.")
            return

    except Exception as e:
        print(f"Error parsing Pub/Sub message: {e}")
        return # Don't proceed if message is invalid

    # 2. Disable the target API
    client = serviceusage_v1.ServiceUsageClient()
    service_name = f"projects/{PROJECT_ID}/services/{API_TO_DISABLE}"

    print(f"Attempting to disable service: {service_name}")

    try:
        # Construct the request
        request = serviceusage_v1.DisableServiceRequest(
            name=service_name
        )
        # Make the API call
        operation = client.disable_service(request=request)
        print(f"Waiting for operation {operation.name} to complete...")
        
        # Wait for the operation to complete
        response = operation.result(timeout=300) # 300-second timeout
        print(f"Successfully disabled service: {response.service.name}")

    except exceptions.FailedPrecondition as e:
        # This often means the service is already disabled
        print(f"Service may already be disabled: {e.message}")
    except Exception as e:
        print(f"An error occurred while disabling the service: {e}")

```

-----

### 🛑 Alternative (Safer) Action: Disable All Billing

Disabling a single API might not stop all associated costs (like storage). The most effective "hard stop" is to **disable billing for the entire project**.

If you want to do this, use the code below in your Cloud Function instead.

1.  **Permission:** Your function's service account will need the **`Billing Administrator`** (`roles/billing.admin`) role instead of `Service Usage Admin`.
2.  **`requirements.txt`:** Add `google-cloud-billing`
3.  **`main.py`:**

<!-- end list -->

```python
import base64
import json
from google.cloud import billing_v1

# --- Configuration ---
# TODO: Change this value
PROJECT_ID = "your-gcp-project-id"
# ---------------------

def disable_project_billing(event, context):
    """
    Triggered by a Pub/Sub message from a Cloud Billing Budget.
    Disables billing for the entire project.
    """
    print(f"Function triggered by messageId: {context.message_id}")
    
    # ... (Add the same message parsing logic from the first example here) ...

    print(f"Attempting to disable billing for project: {PROJECT_ID}")
    client = billing_v1.CloudBillingClient()
    
    # Construct the request to detach the billing account
    request = billing_v1.UpdateProjectBillingInfoRequest(
        name=f"projects/{PROJECT_ID}",
        project_billing_info=billing_v1.ProjectBillingInfo(
            billing_account_name="" # Setting to empty string disables billing
        ),
    )
    
    try:
        response = client.update_project_billing_info(request=request)
        print(f"Successfully disabled billing for project {response.project_id}.")
    except Exception as e:
        print(f"Error disabling billing: {e}")

```

-----

### ⚠️ Important Warnings

  * **Time Lag:** This system is **not instantaneous**. Cloud Billing data can be delayed (from minutes to a few hours). This routine will execute *after* you have already passed your budget. It is a "stop the bleeding" tool, not a perfect preventative cap.
  * **How to Re-enable:** This workflow **only disables** the service (or billing). You must manually go into the console the next day to re-enable the API or re-link your billing account.
  * **Powerful Permissions:** The roles `Service Usage Admin` and `Billing Administrator` are extremely powerful. Be very careful with the service account that holds them.