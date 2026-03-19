environment         = "staging"
install_platform    = true
deployment_profile  = "minimal"   # or "graviton" for ~20% savings; or "spot" with use_rds+enable_efs
use_rds             = true
# rds_subnet_ids = ["subnet-aaaaaaaaaaaaaaaa1", "subnet-aaaaaaaaaaaaaaaa2"]
