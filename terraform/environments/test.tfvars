environment         = "test"
# aws_region = "us-east-1"   # set this if not us-east-1 — must be passed at both apply AND destroy time
install_platform    = false
deployment_profile  = "minimal"   # t3.medium on-demand (~$30/mo)
use_rds             = false        # local MariaDB saves ~$55/mo for test
enable_alb          = false        # certbot TLS directly on instance
enable_vpc_endpoints = false       # save ~$35/mo; SSM routes via internet
enable_waf          = false        # requires enable_alb=true
enable_efs          = false        # single instance; local disk is fine
