environment         = "prod"
# aws_region = "us-east-1"   # set this if not us-east-1 — must match at apply AND destroy time
install_platform    = true
deployment_profile  = "minimal"   # or "graviton"; spot not recommended for prod
use_rds             = true
# rds_subnet_ids = ["subnet-aaaaaaaaaaaaaaaa1", "subnet-aaaaaaaaaaaaaaaa2"]
