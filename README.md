# news-feed-infra

News feed infrastrucre

## How to create the project that holds the backend bucket

```bash
export PROJECT_ID="bootstrap-terragrunt-gcs-01"
export ORG_ID="828057377450"
export BILLING_ACCOUNT="016D8A-BB164C-D03600" # don't forget to remove this (don't commit this)

gcloud projects create ${PROJECT_ID} \
  --name="Terragrunt GCS bucket project" \
  --organization=${ORG_ID}

gcloud billing projects link ${PROJECT_ID} \
  --billing-account=${BILLING_ACCOUNT}

gcloud projects list

export BUCKET_NAME="news-app-infra-terragrunt-state"
gcloud storage buckets create gs://$BUCKET_NAME \
  --location EU \
  --uniform-bucket-level-access \
  --project ${PROJECT_ID}

# Enabled versioning for GCE terragrunt state
gsutil versioning set on gs://${BUCKET_NAME} \

gcloud storage buckets list --project $PROJECT_ID
```

### How to create folder

In order to use `project_factory` module into terraform and create the projects under folders
you need to create folders befor either by clickops or via gcloud as follows:

```bash
gcloud resource-manager folders create \
  --display-name=dev \
  --organization=${ORG_ID}
```
