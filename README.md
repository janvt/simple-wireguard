# WireGuard split-tunnel VPN on AWS (Terraform)

A personal WireGuard VPN on an EC2 instance in the AWS region of your choice
(defaults to `eu-central-1`, i.e. a German exit IP) that gives your Mac an exit IP
in that region. Built to be spun up for a session (e.g. a bike race on
Discovery+) and stopped afterwards, with the compute bill only running while it's on.

## How it's put together

Clean split between **build** (Terraform, you run it) and **run** (scripts, no Terraform):

- **Terraform** owns the *static* box: security group (shell), IAM role + instance
  profile, the two Secrets Manager secrets, the SSM parameter, and the instance. You
  run `./setup.sh` once, then `terraform apply` to build or rebuild.
- **`up.sh` / `down.sh`** own the *per-session* dynamics and **never run Terraform**.
  `up.sh` starts the instance, points `vpn.example.com` at its new public IP, and opens
  the firewall to your current source IP — all via the AWS CLI. `down.sh` stops it.
- The **A record** and the **SG ingress rule** are deliberately *not* in Terraform
  (they change every session), so a manual `terraform apply` never fights `up.sh`.
- **`dns/`** is a separate one-time config that creates the Route53 hosted zone for
  `vpn.example.com`. Isolated so a VPN teardown never disturbs the Cloudflare delegation.

### The clever bit — stable hostname, no Elastic IP

The instance uses a **free, auto-assigned public IP** (which changes on each start).
`up.sh` points **`vpn.example.com`** at whatever that IP is, so your client config
dials a stable *name*. You never re-import, and there's no Elastic IP charge.

### Where the keys live

- **Server private key**: generated **on the instance** at first boot and stored in
  **Secrets Manager**. Never in user-data, never in Terraform state. Reused on
  rebuilds (get-or-create), so the server public key stays stable.
- **Server public key**: published to an SSM parameter (not sensitive); `up.sh`
  reads it to render the client config.
- **Client private key**: generated once locally into `client/client.key` (0600),
  never leaves your Mac.

## One-time setup

Use **your own** hostname everywhere `vpn.example.com` appears below.

**1. Record your hostname + generate the client key:**

```bash
cd wg-vpn                       # wherever you cloned the repo
./setup.sh vpn.example.com     # your real hostname; prompts if you omit it
```

Writes your client key and hostname into the git-ignored `terraform.tfvars` and
`dns/terraform.tfvars`, so your real domain never ships in the repo (the committed
defaults are the `vpn.example.com` placeholder).

**2. Create the hosted zone and get the name servers:**

```bash
cd dns && terraform init && terraform apply
terraform output name_servers
cd ..
```

**3. Delegate the subdomain at your DNS host** (e.g. Cloudflare, for `example.com`):
add the four name servers as **NS** records on the `vpn` label:

| Type | Name  | Content                        | Proxy    |
| ---- | ----- | ------------------------------ | -------- |
| NS   | `vpn` | *(name server #1 from output)* | DNS only |
| NS   | `vpn` | *(name server #2)*             | DNS only |
| NS   | `vpn` | *(name server #3)*             | DNS only |
| NS   | `vpn` | *(name server #4)*             | DNS only |

NS records aren't proxyable, so there's no orange cloud to worry about here.

**4. Build the box:**

```bash
terraform init && terraform apply
```

**5. Bring it up:**

```bash
./up.sh
```

Then install the **WireGuard** app (Mac App Store), import
`client/wg-vpn-split.conf` once, and toggle it on.

## Daily use

```bash
./up.sh     # start, point DNS at the new IP, open the firewall to your current IP
./down.sh   # stop it when you're done
```

Neither runs Terraform. The imported tunnel keeps working across sessions — no
re-import needed. If your box ever needs rebuilding, that's the only time you touch
Terraform again (`terraform apply`).

**Credentials `up.sh`/`down.sh` need** (the IAM user/role you run them as): `ec2:StartInstances`,
`ec2:StopInstances`, `ec2:DescribeInstances`, `ec2:DescribeSecurityGroups`,
`ec2:AuthorizeSecurityGroupIngress`, `ec2:RevokeSecurityGroupIngress`,
`route53:ListHostedZonesByName`, `route53:ChangeResourceRecordSets`,
`ssm:GetParameter`, `secretsmanager:GetSecretValue`. (Admin covers all of these.)

## Split tunnel (default) — only stream domains go through the VPN

WireGuard routes by IP, not by domain, so the split is done at the browser layer:

- The instance runs a **Squid forward proxy** on `10.8.0.1:3128`, reachable *only*
  through the tunnel (the security group never exposes it).
- The client's `AllowedIPs` is just the tunnel subnet (`10.8.0.0/24`), so **only
  proxy traffic enters the tunnel** — all your other traffic stays direct.
- `up.sh` writes a **PAC file** (`pac/discovery.pac`) that sends the domains in
  `client/domains.txt` to the proxy and everything else DIRECT. DNS for those
  domains is resolved server-side in the VPN region, which is what makes the unblock work.
- The PAC is served over **`http://127.0.0.1:8899`** by a launchd agent, because
  **macOS silently ignores `file://` PAC URLs** — CFNetwork evaluates PACs
  system-side and only reliably fetches them over http(s); a failed load falls back
  to DIRECT with no error. Serving the same file over localhost http is what makes
  Safari apply it.

**One-time setup:**

```bash
./install-pac-server.sh   # generates + loads the launchd agent (serves pac/ on :8899)
```

`install-pac-server.sh` resolves the repo path and a working `python3` automatically,
so **re-run it after moving the repo** or if the server ever stops. (It deliberately
avoids Apple's `/usr/bin/python3` stub, which breaks when the Command Line Tools are
missing/half-installed — a common cause of "split suddenly stopped working".)

Then System Settings ▸ Network ▸ Wi-Fi ▸ Details ▸ Proxies ▸ enable *Automatic
Proxy Configuration* ▸ URL `http://127.0.0.1:8899/discovery.pac`. The PAC returns
`PROXY …; DIRECT`, so when the VPN is down those sites just load directly — set it
once and forget it.

If split silently stops (sites load but show your home country): the PAC server is
almost certainly down. Check `curl -s http://127.0.0.1:8899/discovery.pac` and
`/tmp/vpn-pac.log`, then re-run `./install-pac-server.sh`.

**Change the domain list:** edit `client/domains.txt` (one domain per line,
subdomains matched automatically) and re-run `./up.sh`.

**Want everything routed instead?** `MODE=full ./up.sh` writes a *separate*
`client/wg-vpn-full.conf` (full tunnel, no PAC). Import both once and flip
between the `wg-vpn-split` and `wg-vpn-full` tunnels in the WireGuard
menu bar — but run only one at a time (they share the same client key). Turn the
macOS PAC off when using full mode. In split mode the IPv6-leak question is moot —
general traffic isn't tunnelled at all.

## Firewall lock to your IP

Ingress is `UDP 51820` from **your current public IP only**. `up.sh` detects your
IP each run and updates the SG rule directly via the AWS CLI (revoke the old, add
the current) — so if your residential IP changed since last time, just running
`up.sh` fixes it.

If your IP changes *mid-session* the tunnel drops and won't reconnect until you
re-run `up.sh`. WireGuard is safe exposed either way (silent to unauthenticated
packets); the lock is defense-in-depth.

## Cost

- Running: ~$0.004/hr compute — pennies per race.
- Idle (stopped): **~$1.90/mo** — 8 GB EBS ($0.64) + Route53 zone ($0.50) + two
  Secrets Manager secrets (server key + pre-shared key, $0.40 each). No Elastic IP
  charge.

### Data transfer (the only usage-based cost)

Billed on **data out of AWS to the internet** — the video going from the instance
down the tunnel to your Mac. Inbound (Discovery → instance) is free; only outbound
counts.

- **First 100 GB/month: free** (AWS account-wide allowance).
- Beyond that: **~$0.09/GB** in `eu-central-1`.
- HD streaming (~1080p) uses **~3–4 GB/hour**; SD ~1 GB/hr.

| Usage                                     | Data/mo    | Cost        |
| ----------------------------------------- | ---------- | ----------- |
| Casual — a few stages/week (~15–20 hrs)   | ~60–70 GB  | **$0**      |
| Regular — ~30 hrs/mo                       | ~100–120 GB| **~$0–2**   |
| Grand Tour binge — ~80 hrs in one month   | ~280 GB    | **~$16**    |

**Split tunnel keeps this down**: only proxied (Discovery) traffic flows through AWS
and counts — general browsing, downloads, and OS updates never touch the instance.
Full-tunnel mode routes *everything* through AWS and would inflate this.

Check actual outbound bytes over the last 30 days:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/EC2 \
  --metric-name NetworkOut --dimensions Name=InstanceId,Value=$(terraform output -raw instance_id) \
  --start-time "$(date -u -v-30d '+%Y-%m-%dT%H:%M:%SZ')" --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 2592000 --statistics Sum --region eu-central-1
```

Divide the result by 1e9 for GB; subtract 100, multiply the rest by $0.09.

## Full teardown

```bash
terraform destroy        # removes the VPN (instance, SG, IAM, secret, A record)
```

The `dns/` zone is deliberately **not** touched by this — leave it so you don't have
to redo the Cloudflare delegation. To remove it too: `cd dns && terraform destroy`
(then delete the NS records at Cloudflare).

## Hardening baked in

IMDSv2-only with hop limit 1, source/dest check off, `sshd` disabled (SSM only),
automatic security updates, a **WireGuard pre-shared key** (extra symmetric layer on
both peers, generated on-box → Secrets Manager), and the scoped IAM policy (the
instance can touch only its own secrets + parameter).

### A note on IPv6 (no leak)

The client's `AllowedIPs` keeps `::/0` **on purpose**. This is a v4-only exit, so
IPv6 is *captured* into the tunnel and dropped there. If we removed `::/0`, IPv6
traffic would instead egress over your native connection and expose your real IPv6
address — an IP leak, which defeats the point of a geo-VPN. Modern browsers fall
back from the dropped IPv6 to IPv4 within a few hundred ms (Happy Eyeballs), so the
"hang" is usually imperceptible. The only leak-free way to make IPv6 truly fast is
to give the server real IPv6 egress — a bigger change (the default VPC has no IPv6),
not worth it here.

## Notes

- Auto-assigned IPs still come from AWS's `eu-central-1` pool, so the exit is still
  German.
- Streaming services sometimes block datacenter/AWS IP ranges outright. If Discovery+
  refuses despite a German IP, that's IP reputation, not a config bug.
- Old imperative scripts are archived in `legacy/` for reference.
