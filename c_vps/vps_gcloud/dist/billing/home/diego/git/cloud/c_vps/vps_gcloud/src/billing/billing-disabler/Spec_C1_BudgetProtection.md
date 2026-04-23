# Defensive Cost Control - Budget Protection

This document describes the automated budget protection system that disables billing when spending exceeds the configured threshold.

## Overview

An automated workflow that monitors spending and **automatically disables billing** when the monthly budget of €5 is reached. This prevents unexpected cloud costs from accumulating.

## Architecture

The system uses three GCP services:

1. **Cloud Billing Budget** - Monitors spending and sends alerts at 100% threshold
2. **Pub/Sub Topic** - Receives budget alert messages (`budget-disable-trigger`)
3. **Cloud Function** - Triggered by Pub/Sub to disable billing automatically

## Configuration Details

### Budget Settings
- **Name**: Daily5DollarBudget
- **Amount**: €5/month
- **Threshold**: 100% of current spend
- **Scope**: Project `gen-lang-client-0167192380` (project number: `1029464172302`)
- **Billing Account**: `0138CC-CDC244-E7359D`

### Pub/Sub Topic
- **Topic Name**: `budget-disable-trigger`
- **Full Path**: `projects/gen-lang-client-0167192380/topics/budget-disable-trigger`

### Cloud Function
- **Name**: `billing-disabler`
- **Region**: `us-east1`
- **Runtime**: Python 3.11
- **Trigger**: Pub/Sub message from `budget-disable-trigger` topic
- **Service Account**: `billing-disabler-sa@gen-lang-client-0167192380.iam.gserviceaccount.com`
- **Permissions**: Billing Administrator role at billing account level
- **Entry Point**: `disable_project_billing`
- **URL**: https://us-east1-gen-lang-client-0167192380.cloudfunctions.net/billing-disabler

## How It Works

1. **Spending Monitoring**: The Cloud Billing Budget continuously monitors project spending
2. **Alert Trigger**: When spending reaches €5 (100% of budget), an alert is published to the Pub/Sub topic
3. **Function Execution**: The Cloud Function is automatically triggered by the Pub/Sub message
4. **Billing Disabled**: The function detaches the billing account from the project, effectively disabling all billable services

## Important Warnings

### Time Lag
- Cloud Billing data has a **delay of minutes to hours**
- The system triggers *after* the budget is exceeded
- This is a "stop the bleeding" tool, not a preventative cap
- Some overspending may occur before the function executes

### Manual Re-enablement Required
- Once billing is disabled, services will stop working
- You must **manually re-enable billing** through the GCP Console
- Steps to re-enable:
  1. Go to [Billing Settings](https://console.cloud.google.com/billing)
  2. Select the project `gen-lang-client-0167192380`
  3. Link it back to billing account `0138CC-CDC244-E7359D`

### Service Impact
- All billable services (Compute, Storage, APIs, etc.) will be disabled
- Running VMs will be stopped
- API calls will fail
- Data remains intact but inaccessible until billing is re-enabled

## Source Code Location

The Cloud Function source code is located at:
- **Directory**: `/home/diego/Documents/Git/system/S1_Cloud/billing-disabler-function/`
- **Files**:
  - `main.py` - Function code that disables billing
  - `requirements.txt` - Python dependencies (`google-cloud-billing`)

## Monitoring and Testing

### View Function Logs
```bash
gcloud functions logs read billing-disabler --region=us-east1 --limit=50
```

### Check Budget Status
```bash
gcloud billing budgets list --billing-account=0138CC-CDC244-E7359D
```

### Test Pub/Sub (Manual Trigger)
```bash
gcloud pubsub topics publish budget-disable-trigger \
  --message='{"budgetDisplayName":"Daily5DollarBudget","costAmount":6,"budgetAmount":5}'
```

**⚠️ WARNING**: Testing will actually disable billing! Only use in controlled environments.

## Maintenance

### Update Budget Amount
```bash
gcloud billing budgets update 52f82bfb-74b6-4c20-a100-31b3baa959a0 \
  --billing-account=0138CC-CDC244-E7359D \
  --budget-amount=NEW_AMOUNT
```

### Redeploy Function
```bash
cd billing-disabler-function
gcloud functions deploy billing-disabler \
  --gen2 \
  --runtime=python311 \
  --region=us-east1 \
  --source=. \
  --entry-point=disable_project_billing \
  --trigger-topic=budget-disable-trigger \
  --service-account=billing-disabler-sa@gen-lang-client-0167192380.iam.gserviceaccount.com \
  --max-instances=1
```

### Delete Protection (If Needed)
```bash
# Delete the budget
gcloud billing budgets delete 52f82bfb-74b6-4c20-a100-31b3baa959a0 \
  --billing-account=0138CC-CDC244-E7359D

# Delete the Cloud Function
gcloud functions delete billing-disabler --region=us-east1

# Delete the Pub/Sub topic
gcloud pubsub topics delete budget-disable-trigger

# Delete the service account
gcloud iam service-accounts delete billing-disabler-sa@gen-lang-client-0167192380.iam.gserviceaccount.com
```

## Cost of This Protection System

The budget protection system itself has minimal costs:
- **Cloud Function**: Free tier includes 2M invocations/month (this runs once when triggered)
- **Pub/Sub**: Free tier includes 10GB/month (budget messages are tiny)
- **Cloud Billing Budget**: Free

**Estimated cost**: $0/month under normal usage

## Related Documentation

- Original specification: `About/Pb1_CappedRoutine.md`
- GCP Billing Budgets: https://cloud.google.com/billing/docs/how-to/budgets
- Cloud Functions Documentation: https://cloud.google.com/functions/docs
