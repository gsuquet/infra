---
status: accepted
date: 2026-11-18
decision-makers: gsuquet
---

# Expose public services through Cloudflare Tunnel

## Context and Problem Statement

Raspberry Pis and local servers sit behind a home connection with no stable public IP and no inbound ports.
Domains are already on Cloudflare (landing zone `landing-zone/cloudflare`). How do services become public?

## Decision Drivers

* No inbound port on the home network.
* One exposure model for every target.
* Access policies (Cloudflare Access) in front of private applications.

## Considered Options

* Cloudflare Tunnel via a `cloudflared` component
* Public load balancer per cluster (cloud) and port forwarding (home)
* A VPN or overlay network only

## Decision Outcome

Chosen option: "Cloudflare Tunnel via a `cloudflared` component". `cloudflared` runs in the cluster as an
opt-in component, connects outbound to Cloudflare, and forwards to the cluster's Gateway.

### Consequences

* Good, because no inbound port and no public IP needed.
* Good, because Access applications and policies from the landing zone apply in front of the tunnel.
* Bad, because public traffic depends on Cloudflare.
* Bad, because the tunnel token is a secret: it is delivered through the `secrets` store (ADR-0016), never
  committed.
* Deferred: whether tunnels and DNS records are created by a per-cluster Terraform root or by the tenant layer;
  network allow rules for `cloudflared` egress (ADR-0010).

### Confirmation

No cluster renders a `Service` of type `LoadBalancer` for public traffic without an ADR.

## Pros and Cons of the Options

### Cloudflare Tunnel

* Good, because works behind NAT and CGNAT.
* Bad, because vendor lock-in for the public edge.

### Load balancer and port forwarding

* Good, because no third party.
* Bad, because exposes the home IP and differs per target.

### VPN only

* Good, because private by default.
* Bad, because not public.
