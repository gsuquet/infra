# Local state: a throwaway kind cluster with no credentials, the one kind of
# root agents may apply and destroy (CLAUDE.md).
terraform {
  required_version = "1.17.2"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "0.13.0"
    }
  }
}
