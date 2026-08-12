provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource in the stack. Resources whose provider
  # support for tagging is incomplete are tagged explicitly at the resource.
  default_tags {
    tags = var.tags
  }
}
