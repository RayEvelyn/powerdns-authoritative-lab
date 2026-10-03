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

## Actual CI deployment: use your private deployment copy

The public source is `https://github.com/RayEvelyn/powerdns-authoritative-lab.git`. Public examples run **hosted validation only**. The deployment job is intentionally ineligible in the public repository. Clone the code, review it, and create your **own private** repository/project for access to a dedicated homelab runner:

```bash
git clone https://github.com/RayEvelyn/powerdns-authoritative-lab.git
cd powerdns-authoritative-lab
# Replace YOUR_ACCOUNT with your own account; preserve the upstream origin.
gh repo create YOUR_ACCOUNT/powerdns-authoritative-lab --private --source . --remote deployment --push
```

This includes a functional deployment path, not a claim that CI has deployed your lab already. The GitHub workflow requires an explicit `workflow_dispatch`, your private repository, its default branch, `DEPLOY_ENABLED=true`, runner labels `self-hosted,linux,homelab`, and environment `homelab`. Never attach a LAN-capable self-hosted runner to the public source repo. Configure protected branch/environment controls and restrict runner use to this private copy. Environment approval features depend on your GitHub plan; verify enforced behavior rather than assuming an environment name creates approval.

### A persistent runner and explicit state ownership

Use a dedicated persistent Linux runner with Terraform, Python3, OpenSSH tools, GNU `flock`, and network reachability to the intended lab host. State is not a CI cache or disposable workspace. Provision a private directory owned by the runner service account:

```bash
# On the dedicated runner; use its actual service account instead of homelab-runner.
sudo install -d -m700 -o homelab-runner -g homelab-runner /var/lib/homelab-terraform
```

`TF_STATE_ROOT=/var/lib/homelab-terraform` and the private repository ID resolve to `/var/lib/homelab-terraform/<repository-id>/terraform.tfstate`. The local backend is explicit. A per-state `flock`, Terraform's local locking and CI per-repository concurrency serialize execution. This is **one persistent runner**, not a distributed locking design. Do not schedule the same state on multiple hosts. Back up this root independently; the helper preserves a timestamped private pre-apply state copy, which is not a substitute for off-host recovery. Never upload state or plans as public artifacts.

The helper defaults to `plan`. It generates protected temporary inputs, validates, creates a saved plan, and rejects delete/replacement actions. `plan` exits without changing infrastructure. `provision` applies that exact plan and returns without SSH/bootstrap. `deploy` applies the exact plan, then uses an isolated SSH configuration to install/update the reviewed sample. No automatic destroy is included. Planned replacements require separate deliberate recovery review.

### Configure inputs using CLI

Define your target with nonsecret JSON in repository variable `HOMELAB_TFVARS_JSON`; do not put tokens, passwords or private keys there. For the DNS VM examples, use the fields from `terraform/terraform.tfvars.example`, omitting `ssh_public_key_path`: the helper writes the provided public key to a temporary file and supplies the path. For Cloudflare, use `zone_id`, `hostname`, and the **existing** `tunnel_id`. An API token is provider environment input, never a Terraform credential variable.

```bash
# Run against your private repository. Files below belong outside the public checkout.
gh api --method PUT repos/YOUR_ACCOUNT/powerdns-authoritative-lab/environments/homelab
gh variable set TF_STATE_ROOT --repo YOUR_ACCOUNT/powerdns-authoritative-lab --body /var/lib/homelab-terraform
gh variable set HOMELAB_TFVARS_JSON --repo YOUR_ACCOUNT/powerdns-authoritative-lab < /secure/local/inputs.json
# The public SSH key is not a secret; match the protected private key used for deployment.
gh variable set SSH_PUBLIC_KEY --repo YOUR_ACCOUNT/powerdns-authoritative-lab < /secure/local/id_ed25519.pub
gh secret set SSH_PRIVATE_KEY --repo YOUR_ACCOUNT/powerdns-authoritative-lab < /secure/local/id_ed25519
gh secret set SSH_KNOWN_HOSTS --repo YOUR_ACCOUNT/powerdns-authoritative-lab < /secure/local/known_hosts
# Enable only after reviewing runner placement, inputs and permission boundaries.
gh variable set DEPLOY_ENABLED --repo YOUR_ACCOUNT/powerdns-authoritative-lab --body true
gh workflow run homelab.yml --repo YOUR_ACCOUNT/powerdns-authoritative-lab -f action=plan
```

Secret commands read stdin; credential values are not command-line arguments. Disable shell tracing and avoid logged terminals when handling secrets. Do not echo credentials for troubleshooting. Keep an independently verified host-key file rather than trusting an unauthenticated `ssh-keyscan` result.

DNS Terraform also needs `PROXMOX_VE_ENDPOINT` as a variable, `PROXMOX_VE_API_TOKEN` as a secret, and optionally `PROXMOX_CA_PEM` as a secret containing your trusted CA. Example input commands:

```bash
gh variable set PROXMOX_VE_ENDPOINT --repo YOUR_ACCOUNT/powerdns-authoritative-lab --body https://proxmox.example.test:8006/
gh secret set PROXMOX_VE_API_TOKEN --repo YOUR_ACCOUNT/powerdns-authoritative-lab < /secure/local/proxmox-token
gh secret set PROXMOX_CA_PEM --repo YOUR_ACCOUNT/powerdns-authoritative-lab < /secure/local/proxmox-ca.pem
```

The optional CA is appended to the platform trust bundle and used through `SSL_CERT_FILE`; TLS verification stays enabled. Grant only intended lab permissions. SSH uses `SSH_PRIVATE_KEY` and preverified `SSH_KNOWN_HOSTS` in a mode600 temporary configuration. Every invocation explicitly passes `-F "$HOMELAB_SSH_CONFIG"`; no existing user SSH settings or hooks are replaced. The target user defaults to `ubuntu`, port22, and must have the intended passwordless `sudo` authority for this disposable guest. This is broad guest administration, not a production least-privilege deployment identity.

### Provision first; pin a unique guest host key; then deploy

For a new Proxmox guest, run `action=provision` before `action=deploy`. Provision needs only the public SSH key, Terraform inputs and provider credential; known-host keys are not required yet. The output identifies the static guest address. Use your trusted Proxmox CLI/guest-agent path to read the **new guest's** public host key and verify its fingerprint, then place that exact key in `SSH_KNOWN_HOSTS`. For example, on the trusted Proxmox node:

```bash
qm guest exec YOUR_VM_ID -- cat /etc/ssh/ssh_host_ed25519_key.pub
# Compare its fingerprint through your trusted administration path, then privately
# store "GUEST_IP ssh-ed25519 PUBLIC_KEY" in known_hosts (nondefault ports use [IP]:PORT).
```

Never clone host private keys into multiple VMs. Prepare templates with guest-agent installed, remove template host keys and clean cloud-init identity before converting to a template; ensure each clone generates fresh host keys. A login public key identifies the deploy user; it is different from the server host key. Host-key failures are not fixed by disabling verification.

The DNS deploy phase bootstraps Docker inside the new Linux guest, uploads only reviewed Compose/config/zone/helper files, preserves previous release configuration under `/var/backups/homelab/powerdns-authoritative-lab/`, and starts the new release under `/opt/homelab/powerdns-authoritative-lab/releases/`. No existing user configuration is replaced. Container data and host backups still require your separate backup policy. No firewall is disabled.

### Real DNS clients need a deliberate listener and ACL

The hosted/local demo stays loopback/high-port. For actual DNS deployment, set nonsecret variable `DNS_BIND_IP` to the guest's **specific intended IPv4 LAN address**; deployment exposes TCP/UDP53 on that address. `DNS_ALLOWED_CIDRS` is required for the Recursor and is a comma-separated list of explicitly trusted client CIDRs. `0.0.0.0/0` and `::/0` are refused. The helper supports an IPv4 listener; design and test IPv6 separately instead of claiming it is configured.

```bash
gh variable set DNS_BIND_IP --repo YOUR_ACCOUNT/powerdns-authoritative-lab --body YOUR_GUEST_LAN_IP
# Recursor only: replace with your narrow intended client networks.
gh variable set DNS_ALLOWED_CIDRS --repo YOUR_ACCOUNT/powerdns-authoritative-lab --body YOUR_TRUSTED_CIDR
gh workflow run homelab.yml --repo YOUR_ACCOUNT/powerdns-authoritative-lab -f action=provision
# Pin independently verified guest keys, then:
gh workflow run homelab.yml --repo YOUR_ACCOUNT/powerdns-authoritative-lab -f action=deploy
```

The application sees the translated Docker bridge source in some paths; the deployed Recursor also permits its dedicated bridge. That does not prove every original client is authorized. Enforce allowed/denied client networks at your router/firewall and test from both. Authoritative DNS should be restricted to your intended internal resolver clients. The helper does not automatically set router ACLs, change DHCP client DNS, expose WAN services, or prove Proxmox network isolation. Those are explicit acceptance checks.

### Existing bare-metal or VM target

The same workload upload is available through `scripts/deploy-existing-host.sh` for a dedicated Linux host without Terraform provisioning. Supply the isolated `HOMELAB_SSH_CONFIG`, runtime directory and deployment inputs exactly as the CI helper does. It requires the same preverified keys, sudo authority and network policy. Review `scripts/deploy-local.py` before running it directly on the intended host; never on a Proxmox hypervisor. Package installation and container restart are actual changes.

### GitLab option

The included `.gitlab-ci.yml` runs hosted/shared validation and exposes a **manual** homelab job only for a private project, protected default branch and `DEPLOY_ENABLED=true`. Register a dedicated Linux runner tagged `homelab`, assign protected variables/secrets with the same names, and protect the `homelab` environment as your GitLab plan supports. It invokes the same helpers. Default `HOMELAB_ACTION=plan`; deliberately select `provision` or `deploy` only after reviewing the previous stage. Do not attach this runner to untrusted forks or public pipelines.

Repository/runner access controls and token permissions are part of your lab setup; example YAML cannot enforce a router policy or your hosting account's approval settings by itself.

For a complete existing-host command path, load `SSH_PRIVATE_KEY` and `SSH_KNOWN_HOSTS` from your protected local secret facility, set `HOMELAB_SSH_HOST` (and DNS binding/ACL variables for the DNS repos), then run:

```bash
bash scripts/deploy-bare-metal.sh
```

This creates its own temporary isolated SSH files and performs the reviewed guest deployment, with no Terraform apply or VM creation. The existing host must be dedicated to this lab and already have the intended network segmentation and unique host keys. It installs packages and restarts only the named example workload; inspect the helper before using it on a host with existing services.
