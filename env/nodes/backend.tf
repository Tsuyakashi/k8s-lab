terraform {
  backend "s3" {
    endpoints = {
      s3 = "http://192.168.100.100:9000"
    }
    bucket = "k8s-lab-tfstate"
    key    = "nodes/terraform.tfstate"
    region = "us-east-1"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}
