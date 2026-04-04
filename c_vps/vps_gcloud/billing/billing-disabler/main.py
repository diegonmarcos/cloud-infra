import base64
import json
from google.cloud import billing_v1

# --- Configuration ---
PROJECT_ID = "gen-lang-client-0167192380"
# ---------------------

def disable_project_billing(event, context):
    """
    Triggered by a Pub/Sub message from a Cloud Billing Budget.
    Disables billing for the entire project when budget is exceeded.
    """
    print(f"Function triggered by messageId: {context.event_id}")
    print(f"Event: {event}")

    # 1. Parse the budget notification
    try:
        pubsub_data = base64.b64decode(event["data"]).decode("utf-8")
        notification = json.loads(pubsub_data)
        cost_amount = notification.get("costAmount", 0)
        budget_amount = notification.get("budgetAmount", 0)
        budget_display_name = notification.get("budgetDisplayName", "Unknown")

        print(f"Budget notification received for '{budget_display_name}'")
        print(f"Cost: ${cost_amount} | Budget: ${budget_amount}")

        # Optional: Add logic to only fire if cost is above a certain amount
        if cost_amount < budget_amount:
            print("Cost is below budget. No action taken.")
            return

    except Exception as e:
        print(f"Error parsing Pub/Sub message: {e}")
        return  # Don't proceed if message is invalid

    # 2. Disable billing for the project
    print(f"Attempting to disable billing for project: {PROJECT_ID}")
    client = billing_v1.CloudBillingClient()

    # Construct the request to detach the billing account
    request = billing_v1.UpdateProjectBillingInfoRequest(
        name=f"projects/{PROJECT_ID}",
        project_billing_info=billing_v1.ProjectBillingInfo(
            billing_account_name=""  # Setting to empty string disables billing
        ),
    )

    try:
        response = client.update_project_billing_info(request=request)
        print(f"✓ Successfully disabled billing for project {response.project_id}.")
        print(f"⚠️  WARNING: All billable services in project {PROJECT_ID} are now disabled!")
        print(f"⚠️  To re-enable, go to Billing settings in GCP Console.")
    except Exception as e:
        print(f"❌ Error disabling billing: {e}")
