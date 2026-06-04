# Source this file in PowerShell before running Terraform:
#   . .\.env.gcp.ps1

$env:GOOGLE_CLOUD_PROJECT       = "protectportal-498318"
$env:GOOGLE_PROJECT             = "protectportal-498318"
$env:GOOGLE_REGION              = "asia-southeast1"
$env:TF_VAR_project_id          = "protectportal-498318"
$env:TF_VAR_region              = "asia-southeast1"

# Backend config (also baked into versions.tf via -backend-config flags)
$env:TF_BACKEND_BUCKET = "protectportal-498318-tfstate"
$env:TF_BACKEND_PREFIX = "protectportal/prod"

Write-Host "GCP env set: project=protectportal-498318 region=asia-southeast1 state=gs://protectportal-498318-tfstate/protectportal/prod" -ForegroundColor Green
