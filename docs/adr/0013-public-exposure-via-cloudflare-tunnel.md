---
adr: 0013
title: Expose public services through Cloudflare Tunnel
status: accepted
date: 2026-11-18
rfc: docs/rfc/0013-public-exposure-via-cloudflare-tunnel.md
review: https://github.com/gsuquet/infra/pull/5
---

# 0013. Expose public services through Cloudflare Tunnel

- Status: accepted on 2026-11-18 by gsuquet
- Decision: In the context of exposing services from clusters behind a home connection with no public IP and from the cloud, facing inbound ports and one model per target, we decided for Cloudflare Tunnel through an opt-in `cloudflared` component that connects outbound to Cloudflare and forwards to the cluster's Gateway (tunnel token delivered through the `secrets` store, never committed; a cluster root's Cloudflare token least-privileged, with no account-wide Access edit; account-wide and platform Access applications kept in `landing-zone/cloudflare`), and against a public load balancer with port forwarding and a VPN only, to achieve public services with no inbound port behind Access, accepting Cloudflare as the only public edge.
- Consequences:
  - Good: no inbound port and no public IP needed.
  - Good: Access applications and policies from the landing zone apply in front of the tunnel.
  - Good: amended 2026-11-19: a cluster root's Cloudflare token is least-privileged, so a leaked one cannot change account-wide Access; account-wide and platform Access applications stay in `landing-zone/cloudflare`.
  - Bad: public traffic depends on Cloudflare.
  - Bad: the tunnel token is a secret to deliver through the `secrets` store.
  - Bad: deferred: whether tunnels and DNS records come from a per-cluster IaC root or the tenant layer (RFC 0026), and the `cloudflared` egress allow rules (RFC 0010).
- Confidence: high, the tunnel model already runs for `olympus` in `homelab`.
- Confirmation: no cluster exposes a `Service` or `Gateway` on a public IP without an RFC; `LoadBalancer` Services with private addresses (Cilium LB-IPAM on the LAN) are allowed; no cluster root token has account-wide Access edit permission.
- Revisit when: Cloudflare pricing or terms change for tunnels, or a service needs a non-HTTP public protocol the tunnel does not carry.

Source: [RFC 0013](../../docs/rfc/0013-public-exposure-via-cloudflare-tunnel.md), reviewed in https://github.com/gsuquet/infra/pull/5.
