terraform {
  backend "s3" {
    bucket         = "elastiflix-terraform-state-an619"
    key            = "eks/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
