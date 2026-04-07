// Azure resources for offsite backup of vdhinfra MinIO buckets.
//
// Provisions:
//   - Storage account (StorageV2, LRS, Cool tier default)
//   - One private blob container "vdhinfra-backups"
//   - Lifecycle management policy: blobs >90d → Archive, >365d → delete
//
// Deploy with:
//   az login
//   az group create --name rg-vdhinfra-backups --location westeurope
//   az deployment group create \
//     --resource-group rg-vdhinfra-backups \
//     --template-file infrastructure/azure/main.bicep \
//     --parameters infrastructure/azure/parameters.json
//   az storage account keys list \
//     --resource-group rg-vdhinfra-backups \
//     --account-name vdhinfrabackups \
//     --query '[0].value' -o tsv
//   # Paste the output into 1Password "minio" item, field AZURE_STORAGE_KEY

@description('Location for all resources. westeurope keeps things in NL/IE for low latency from the homelab.')
param location string = 'westeurope'

@description('Storage account name. Must be globally unique, lowercase, 3-24 chars, alphanumeric only.')
param storageAccountName string = 'vdhinfrabackups'

@description('Container name where MinIO buckets are mirrored. Subprefixes /cnpg-backups/ and /volsync/ are created on first sync.')
param containerName string = 'vdhinfra-backups'

@description('Default access tier. Cool ($0.01/GB/mo) is the recommended tier for backups read rarely.')
@allowed([
  'Hot'
  'Cool'
  'Cold'
])
param accessTier string = 'Cool'

@description('Days after which a blob moves to the Archive tier (cheaper, slow restore).')
param archiveAfterDays int = 90

@description('Days after which a blob is permanently deleted. Must be larger than your longest barman/restic retention window.')
param deleteAfterDays int = 365

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    // LRS = Locally Redundant (3 copies in one datacenter). Cheapest.
    // Use ZRS if you want intra-region redundancy at ~25% extra cost.
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: accessTier
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true   // required for the rclone CronJob auth
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        blob: { enabled: true, keyType: 'Account' }
        file: { enabled: true, keyType: 'Account' }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      // Soft-delete: deleted blobs are recoverable for 14 days. Cheap insurance
      // against the rclone sync accidentally pruning everything.
      enabled: true
      days: 14
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    isVersioningEnabled: false  // restic + barman are themselves versioned
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
    metadata: {
      managedBy: 'vdhinfra'
      purpose: 'minio-offsite-mirror'
    }
  }
}

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'archive-old-then-delete'
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['${containerName}/']
            }
            actions: {
              baseBlob: {
                tierToArchive: {
                  daysAfterModificationGreaterThan: archiveAfterDays
                }
                delete: {
                  daysAfterModificationGreaterThan: deleteAfterDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

output storageAccountName string = storage.name
output containerName string = container.name
output blobEndpoint string = storage.properties.primaryEndpoints.blob
