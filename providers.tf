################################################################################
# Providers
#
# The default "aws" provider (the compute region) is inherited from the caller.
# Route53 public-zone query logging must live in us-east-1, so the module owns a
# dedicated us-east-1-aliased provider for that plumbing. It uses the same
# default credential resolution as the caller's default provider.
################################################################################

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
