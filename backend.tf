# terraform {
#   backend "s3" {
#     bucket         = "final-project-terraform-state-bucket-test"
#     key            = "final-project/terraform.tfstate"
#     region         = "eu-central-1"
#     dynamodb_table = "terraform-locks"
#     encrypt        = true
#   }
# }

