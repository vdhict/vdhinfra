# Azure offsite backup infrastructure

Bicep manifest for the Azure resources backing the cluster's offsite backup mirror.

## What gets provisioned

| Resource | Purpose | Cost (current data) |
|---|---|---|
| Storage account `vdhinfrabackups` | StorageV2, LRS, Cool tier default | ~$0.02/month at 1.5 GiB |
| Blob container `vdhinfra-backups` | Mirror destination, private access | included |
| Lifecycle policy | >90d → Archive, >365d → Delete | reduces cost over time |
| Soft-delete (14 days) | Recover from accidental rclone prune | free |

The cluster's `minio-offsite-mirror` CronJob (in `kubernetes/main/apps/storage/minio-offsite-mirror/`) writes to this container daily at 04:30 Europe/Amsterdam, mirroring `s3://cnpg-backups` and `s3://volsync` from the in-cluster MinIO.

## First-time deployment

```bash
# 1. Log in to Azure
az login

# 2. Create the resource group (one-time)
az group create \
  --name rg-vdhinfra-backups \
  --location westeurope

# 3. Deploy
az deployment group create \
  --resource-group rg-vdhinfra-backups \
  --template-file infrastructure/azure/main.bicep \
  --parameters infrastructure/azure/parameters.json

# 4. Capture the storage account key
az storage account keys list \
  --resource-group rg-vdhinfra-backups \
  --account-name vdhinfrabackups \
  --query '[0].value' \
  -o tsv

# 5. Add the key to 1Password
#    Item: minio
#    Add field: AZURE_STORAGE_ACCOUNT = vdhinfrabackups
#    Add field: AZURE_STORAGE_KEY     = <output of step 4>
#    Add field: AZURE_CONTAINER       = vdhinfra-backups
```

After step 5 the cluster's ExternalSecret will sync within 12h, or you can force it:

```bash
kubectl -n storage annotate externalsecret minio-offsite-mirror force-sync="$(date -u +%FT%TZ)" --overwrite
```

The first scheduled CronJob run is the next 04:30. You can also trigger it manually:

```bash
kubectl -n storage create job --from=cronjob/minio-offsite-mirror minio-offsite-mirror-now
kubectl -n storage logs job/minio-offsite-mirror-now -f
```

## Updating the deployment

The Bicep template is idempotent — re-running step 3 with modified parameters applies a delta. Common changes:

```bash
# Switch to Cold tier (cheaper storage, more expensive read)
az deployment group create \
  --resource-group rg-vdhinfra-backups \
  --template-file infrastructure/azure/main.bicep \
  --parameters infrastructure/azure/parameters.json \
  --parameters accessTier=Cold

# Adjust deletion window (default 365 days)
az deployment group create \
  --resource-group rg-vdhinfra-backups \
  --template-file infrastructure/azure/main.bicep \
  --parameters infrastructure/azure/parameters.json \
  --parameters deleteAfterDays=730
```

## Disaster recovery: restoring from Azure

If both the cluster AND the Synology NAS are lost, the offsite copy is the only surviving backup. To restore:

```bash
# 1. Provision a new MinIO somewhere (or use any S3-compatible target)

# 2. Use rclone or azcopy to pull the entire container down
rclone copy azure:vdhinfra-backups/ ./local-restore/

# 3. Upload the cnpg-backups/* and volsync/* trees back into your new MinIO

# 4. Run the standard DR procedure:
#    - hack/disaster-recovery/20-restore-postgres.sh
#    - hack/disaster-recovery/30-restore-volsync-all.sh
```

The DR runbook (`docs/runbooks/disaster-recovery.md`) §A covers the full procedure.

## Cost monitoring

Azure cost can be checked at:

```bash
az consumption usage list \
  --start-date 2026-04-01 \
  --end-date 2026-04-30 \
  --query "[?contains(instanceName, 'vdhinfrabackups')].{date:usageStart, cost:pretaxCost, currency:currency}" \
  -o table
```

Set a budget alert at $1/month — anything higher means something's wrong (e.g. data leak or wrong tier):

```bash
az consumption budget create \
  --resource-group rg-vdhinfra-backups \
  --budget-name vdhinfra-backups-monthly \
  --amount 1 \
  --time-grain Monthly \
  --start-date 2026-04-01 \
  --end-date 2027-04-01
```
