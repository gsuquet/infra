# Landing zones

One Terraform root module per provider account: the long-lived foundations that clusters and tenants build on.
A landing zone does not create clusters (see [`clusters/`](../clusters/)).

| Folder | Content | State |
| --- | --- | --- |
| [`cloudflare/`](cloudflare/) | R2 state bucket, domains, Zero Trust foundation | R2, `landing-zone/cloudflare/terraform.tfstate` |
| `gcp/` (planned) | Projects, IAM and network for GKE | R2 |

Child modules used by a landing zone live in [`modules/`](../modules/), not below the root
([ADR-0017](../docs/adr/0017-repository-layout.md)).
