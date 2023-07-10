terraform {
  required_version = "~> 1.4.6" # "~>" - allows only the rightmost increment

  # Providers
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.7.0"
    }
  }
}
