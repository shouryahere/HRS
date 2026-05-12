# Remote state backend — bucket and DynamoDB table created by scripts/bootstrap.sh.
# Run bootstrap.sh ONCE before `terraform init`.
terraform {
  backend "s3" {
    bucket         = "hrs-platform-terraform-state"
    key            = "production/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "hrs-platform-terraform-locks"
  }
}
