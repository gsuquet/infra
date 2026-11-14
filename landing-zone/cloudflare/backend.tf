# State lives in the R2 bucket created by this same configuration (cloudflare_r2_bucket.state).
# First apply: see README "Bootstrap". The bucket name must match var.state_bucket_name (backends can't use variables).
#
# Environment:
#   AWS_ENDPOINT_URL_S3   = https://<account_id>.r2.cloudflarestorage.com
#   AWS_ACCESS_KEY_ID     = R2 API token access key ID
#   AWS_SECRET_ACCESS_KEY = R2 API token secret access key
terraform {
  backend "s3" {
    bucket       = "terraform-state"
    key          = "landing-zone/cloudflare/terraform.tfstate"
    region       = "auto"
    use_lockfile = true # relies on R2 conditional writes (If-None-Match)

    # R2 is S3-compatible but not AWS: skip AWS-only checks.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
