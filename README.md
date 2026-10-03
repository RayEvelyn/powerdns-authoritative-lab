# PowerDNS: understand authoritative DNS and split DNS

Start with [GitOps, the bootstrap order, and why the repos are separate](docs/START-HERE.md).

A beginner lab for answering the same name differently inside and outside a home lab. Start here if DNS still feels like a collection of mysterious router settings.

## Why this matters

DNS turns names into addresses. An **authoritative server** is the source of truth for a zone you own; a **recursive resolver** finds answers on behalf of clients and caches them. They are different jobs. PowerDNS provides separate programs for each job.

Split DNS lets `www.example.test` resolve to a private address inside your lab and an external address outside it. Internal clients can reach a service directly without hairpin NAT, and private services do not need public DNS records. It also makes migrations easier: applications keep stable names while addresses change.

DNS is not access control. A private address or an absent public record does not stop someone who can reach your network from accessing a service. Keep private DNS behind a firewall, put public-facing workloads in a DMZ, and restrict management access.

## What this repository actually runs

Two independent PowerDNS Authoritative 5.0.7 containers with zone files stored in Git:

| Endpoint on your lab machine | Purpose | `www.example.test` | `vault.example.test` |
| --- | --- | --- | --- |
| `127.0.0.1:15353` | Internal answer set | `192.0.2.20` | `192.0.2.30` |
| `127.0.0.1:15354` | External demonstration answer set | `198.51.100.20` | NXDOMAIN |

These are documentation addresses and `.test` names. They intentionally do not reach real websites. The external demonstration remains on loopback; it is not publicly delegated DNS. This separation is the simplest way to see split DNS before using native views.

The BIND backend reads plain zone files. Its API cannot write these zones. Edit files, review the diff, increment the SOA serial, and deploy the reviewed version. No database or API password is required here.

## Start with GitOps and the bootstrap order

GitOps means declaring desired state in version control, reviewing changes, and using automation to reconcile running systems with that state. A Git repo alone is not a reconciliation controller. CI deployment is useful, but continuous drift correction requires a controller or a deliberate scheduled reconciliation process.

1. Prepare your router/firewall, management network, time synchronization and a working bootstrap DNS resolver.
2. Prepare Proxmox or a spare Linux host. Keep the management network separate from the DMZ.
3. Bring up local GitLab independently. Keep an offline copy of its bootstrap configuration and recovery instructions so GitLab does not depend on itself to recover.
4. Store these DNS zone files and the rest of your infrastructure code in GitLab projects. Commit code and sanitized examples, never private keys or secrets.
5. Add a scoped runner and protected deployment jobs. Review plans and diffs before deployment.
6. Add Kubernetes, workload manifests, migrations, KAS and observability as you learn the next layer.

You need bootstrap DNS before local GitLab; the final PowerDNS setup can follow GitLab. Keep an independent admin path if the resolver or GitLab fails.

## Prerequisites

- Docker Engine with Compose v2 on a Linux VM or physical server; Docker Desktop also works for the loopback demonstration.
- `dig` for verification (`sudo apt-get install dnsutils` on Ubuntu).
- Around 1 CPU and 1 GiB RAM for this small demonstration, plus image storage.
- Basic understanding of a host address, subnet, gateway and VLAN. A VLAN separates traffic only when the router/firewall enforces the boundaries.

On a fresh Ubuntu 24.04 lab guest, install the distribution packages using CLI:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 dnsutils
sudo systemctl enable --now docker
```

Use `sudo docker ...` if your user lacks Docker access. Membership in the Docker group grants effectively root-level access; do not add untrusted users. These commands belong on the lab guest, not on your Proxmox hypervisor.

## Run the demonstration

```bash
docker compose config --quiet
docker compose up -d
./scripts/verify.sh
docker compose logs --tail=50
```

Test the two views of the name yourself:

```bash
dig @127.0.0.1 -p 15353 www.example.test A
dig @127.0.0.1 -p 15354 www.example.test A
dig @127.0.0.1 -p 15354 vault.example.test A
```

The first answer is private-demo data, the second is external-demo data, and the third is NXDOMAIN. Look for the `aa` flag: the answer is authoritative. This server will not recursively resolve unrelated domains for you.

## Proxmox versus bare metal

**Proxmox** runs virtual machines on a physical host. A VM template is a reusable starting image; cloud-init sets the clone's address and SSH public key. Terraform should own the guest VM, CPU, RAM, disk and NIC. Run this Compose project inside that guest. The included `terraform/` example clones an existing Ubuntu cloud-init template; see its README for API credentials and exact inputs. Creating a VM does not install this application by itself.

**Bare metal** means running directly on a dedicated physical Linux machine. Skip Terraform's VM creation step, install Ubuntu and Docker on that machine, and use the same Compose files. Do not run the installer on a machine that already owns important DNS services without checking port use and backups first.

The safe loopback binding makes remote DNS clients unable to query this demo. To turn it into a real internal DNS server, replace the internal binding with the VM's specific trusted address and port 53, allow both TCP and UDP 53 from your internal resolver, and test from an allowed and a denied network. Do not expose the private zone instance to the WAN. A local host firewall is insufficient if container networking bypasses its rules; enforce the boundary at the VLAN router/firewall too.

For public DNS without a public home IP, keep public authority at a managed provider such as Cloudflare and use a Tunnel for the website. Cloudflare Tunnel does not replace DNS authority and does not publish an arbitrary UDP/TCP DNS service to the internet. You do not need to publicly expose PowerDNS just to host a website.

## Native PowerDNS views: important backend and version limits

PowerDNS Authoritative added experimental native views in version 5.0. They currently require the **LMDB backend**, `views=yes`, and a nonzero `zone-cache-refresh-interval`. This repository uses the BIND backend and therefore does not enable native views. Do not paste BIND `view {}` clauses into its zone configuration expecting them to work.

With LMDB, zone variants such as `example.test..internal` contain different answer sets. `pdnsutil network set` associates a source network with a view, and `pdnsutil view add-zone` selects the variant. The most specific matching network wins. Unmatched sources use the ordinary zone, so that ordinary zone must contain public-safe data.

Authoritative servers usually see the **recursive resolver's source address**, not the original laptop's address. If all queries come from one shared resolver, source-based views cannot distinguish LAN and DMZ clients unless you separate resolver paths or deliberately configure and trust EDNS Client Subnet. Never blindly trust client-supplied identity data. Test the exact network path and cache behavior before choosing native views.

## Connect an internal caching resolver

Clients should normally query a Recursor, which forwards your internal zone to the internal authoritative server and resolves other domains normally. Use the companion PowerDNS Recursor example. For a real private domain under a signed public parent, DNSSEC treatment needs a deliberate design; do not disable validation globally to hide a forwarding mistake.

Forwarding a whole zone does not mean missing names fall back to public DNS. An authoritative NXDOMAIN is a final answer. If you shadow an entire public domain internally, include the public records internal users still need, or use a dedicated internal subdomain instead.

## Repository ownership and why it is separate

| Repository type | Owns | Why separate it |
| --- | --- | --- |
| Terraform | VM, network attachment, storage, DNS-provider resources | Infrastructure changes can replace or destroy resources and need separate review |
| Manifests | Kubernetes Deployments, Services, policies and Helm values | Workloads change more often than the hosts they run on |
| Flyway | Versioned SQL schema migrations | Database changes need ordered execution and data-aware recovery |
| Application | Source code and container build | A build should not automatically gain infrastructure-admin privileges |

For this small Compose lab, zone files and Compose replace Kubernetes manifests. The same ownership principle applies. Give only one system ownership of each zone or resource to avoid competing writers.

KAS is GitLab's agent server. The cluster-side agent opens an outbound connection to KAS, allowing authorized CI jobs to access Kubernetes through that connection. It does not make the cluster secure automatically: scope `ci_access`, protect deployment jobs and constrain Kubernetes RBAC. Never commit an agent token or a cluster-admin kubeconfig. You do not need KAS for this Compose demonstration.

## Operations, backups and troubleshooting

- Change a record in a new branch, increment the SOA serial, review the zone diff, deploy, then query both answer sets. Record verification in the change.
- Keep Git history and a separate backup of any database backend or signing keys you add later. Git is not a backup for secrets or runtime databases.
- If queries time out, inspect container logs, host bindings, TCP/UDP firewall rules and route reachability.
- If an answer looks old, check TTL and query the authoritative endpoint directly. Cached answers elsewhere may remain until TTL expires.
- If private names appear in the external answer set, stop deployment and inspect both zone files and resolver forwarding paths.
- Refused AXFR is intentional: unrestricted zone transfers can disclose an entire private zone. Use TSIG and restricted peers if you later configure secondaries.

Cleanup stops only these containers:

```bash
docker compose down
```

Do not destroy the VM until you have backed up anything important added after this demo.

## Sources and scope

- [PowerDNS products](https://doc.powerdns.com/index.html)
- [Authoritative BIND backend](https://doc.powerdns.com/authoritative/backends/bind.html)
- [Native views, requirements and matching rules](https://doc.powerdns.com/authoritative/views.html)
- [Recursor getting started](https://docs.powerdns.com/recursor/getting-started.html)

Images are version- and digest-pinned. Local verification is documented in `VALIDATION.md`; a Docker test is not proof that your Proxmox network or production DNS delegation works.
