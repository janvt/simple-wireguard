# WireGuard split-tunnel VPN on AWS (Terraform)

A personal WireGuard VPN on an EC2 instance in the AWS region of your choice
(defaults to `eu-central-1`, i.e. a German exit IP) that gives your devices an exit IP
in that region. Built to be spun up for a session (e.g. a bike race on
Discovery+) and stopped afterwards, with the compute bill only running while it's on.

Supports **multiple profiles** — your Mac, your phone, a friend's laptop — each with
its own key pair and its own address in the tunnel, so they can all be connected at
the same time. See [Profiles](#profiles).

## How it's put together

Clean split between **build** (Terraform, you run it) and **run** (scripts, no Terraform):

- **Terraform** owns the *static* box: security group (shell), IAM role + instance
  profile, the two Secrets Manager secrets, the SSM parameters, and the instance. You
  run `./setup.sh` once, then `terraform apply` to build or rebuild.
- **`./setup.sh`** owns the *profile list*: it generates a key pair per profile, assigns
  each one a tunnel IP, and renders the public half into `terraform.tfvars`.
- **`up.sh` / `down.sh`** own the *per-session* dynamics and **never run Terraform**.
  `up.sh` starts the instance and points `vpn.example.com` at its new public IP via the
  AWS CLI. `down.sh` stops it.
- The **A record** is deliberately *not* in Terraform (it changes every session), so a
  manual `terraform apply` never fights `up.sh`.
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
- **Client private keys**: one per profile, generated locally into
  `client/<profile>/private.key` (0600). A private key only ever leaves this Mac inside
  the `.conf` you deliberately hand to someone. The server never sees it — WireGuard
  authenticates peers by *public* key, which is all that reaches the instance.
- **Peer list**: public keys only, published by Terraform to the `/<name>/peers` SSM
  parameter. The instance syncs its `[Peer]` blocks from there at boot and every two
  minutes, so **adding or removing a profile never rebuilds the box**.

## One-time setup

Use **your own** hostname everywhere `vpn.example.com` appears below.

**1. Record your hostname + generate your first profile's key:**

```bash
cd wg-vpn                       # wherever you cloned the repo
./setup.sh vpn.example.com     # your real hostname; prompts if you omit it
```

Creates a profile called `mac`, generates its key pair, and writes your hostname plus
the profile's *public* key into the git-ignored `terraform.tfvars` and
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
`client/mac/wg-mac-split.conf` once, and toggle it on.

## Daily use

```bash
./up.sh     # start, point DNS at the new IP, render any new configs
./down.sh   # stop it when you're done
```

Neither runs Terraform. The imported tunnel keeps working across sessions — no
re-import needed. If your box ever needs rebuilding, that's the only time you touch
Terraform again (`terraform apply`).

**Credentials `up.sh`/`down.sh` need** (the IAM user/role you run them as): `ec2:StartInstances`,
`ec2:StopInstances`, `ec2:DescribeInstances`,
`route53:ListHostedZonesByName`, `route53:ChangeResourceRecordSets`,
`ssm:GetParameter`, `secretsmanager:GetSecretValue`. (Admin covers all of these.)

## Profiles

Each profile is one WireGuard peer: its **own key pair** and its **own address** in the
tunnel subnet. They're independent, so your Mac, your phone and a friend's laptop can
all be connected at once.

```bash
./setup.sh list                  # what exists, and where each config lands
./setup.sh add phone             # mode 'both'  -> split + full configs
./setup.sh add friend full       # mode 'full'  -> one full-tunnel config
./setup.sh rm  friend            # delete the profile and its key
```

`add` and `rm` only edit local state. To push the change to the server:

```bash
terraform apply    # publishes the new peer list to SSM
./up.sh            # renders configs for any profile that doesn't have one yet
```

The instance re-reads the peer list at boot and every two minutes, so a profile added
while the box is running goes live within a couple of minutes — **no rebuild, and no
disruption to tunnels that are already connected** (the sync uses `wg syncconf`, which
diffs rather than restarts).

### Handing a config to someone

The rendered `.conf` is everything they need — key, server address, PSK. They install
WireGuard (App Store / Play Store), import it, toggle it on. For a phone, skip the file
transfer entirely:

```bash
./setup.sh qr friend             # prints a QR code to scan from the app
```

Needs `brew install qrencode`.

Two practical notes:

- **Give a non-technical person a `full` profile.** Split mode needs the PAC server, the
  launchd agent and a manual macOS proxy setting — none of which they'll want to do. Full
  tunnel is just "toggle on". It costs more egress (see [Cost](#cost)), since *all* their
  traffic crosses the instance.
- **The `.conf` contains a private key.** Send it over something sane — AirDrop, Signal,
  a password-manager share — not plaintext email.

### Who holds which key

`setup.sh` generates each profile's private key locally, so you hold your friend's key as
well as your own. That's fine for a VPN you run for people you know: the only thing it
lets you do is impersonate them *on your own server*, where you already terminate their
traffic. It doesn't expand what you can see.

What matters more is **attribution**: everything every profile does egresses from your
instance, under your AWS account, so abuse reports land on you. Worth holding
deliberately rather than discovering.

If you'd rather not hold someone's key, they can generate their own (`wg genkey`) and
send you only the public half. Add a row to `client/profiles.tsv` by hand — name, the
next free suffix, a mode, their public key, tab-separated — then `terraform apply`. The
server will serve that peer like any other; `up.sh` notes that it has no local key and
renders nothing, so they assemble their own `.conf` from the server public key
(`terraform output server_pubkey_param`), the PSK and their tunnel IP.

### Upgrading from the single-client layout

If you already ran this repo before profiles existed, `./setup.sh` migrates you:
`client/client.key` is copied to `client/mac/private.key` and registered as profile
`mac` at `10.8.0.2` — **same key, same tunnel IP**, so tunnels you've already imported
into WireGuard keep working untouched. The old `client/wg-*.conf` files are left alone
and can be deleted once the new ones are rendered.

```bash
./setup.sh          # migrate; rewrites terraform.tfvars in the new `peers` format
terraform apply     # replaces the instance once (see below), publishes the peer list
./up.sh
```

That first `terraform apply` **replaces the instance**, because the peer-sync machinery
lives in user-data and user-data only runs on first boot. It's safe: the server private
key and the PSK live in Secrets Manager and are re-fetched, so the replacement comes
back with the same identity and every client config stays valid. Subsequent profile
changes do *not* rebuild anything.

It also adds the open UDP 51820 ingress rule. Any `/32` rule left behind by an older
`up.sh` is harmless (it's a subset of the new one) but Terraform won't remove it, since
it never managed it. To tidy up:

```bash
SG=$(terraform output -raw security_group_id)
aws ec2 describe-security-groups --group-ids "$SG" \
  --query "SecurityGroups[0].IpPermissions[?ToPort==\`51820\`].IpRanges[?CidrIp!='0.0.0.0/0'].CidrIp" \
  --output text |
  xargs -n1 -I{} aws ec2 revoke-security-group-ingress \
    --group-id "$SG" --protocol udp --port 51820 --cidr {}
```

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

**Want everything routed instead?** Full tunnel is a per-profile setting, not a global
flag. A profile created with mode `both` (the default) gets *two* configs rendered —
`wg-<profile>-split.conf` and `wg-<profile>-full.conf` — so you import both once and
flip between them in the WireGuard menu bar. Run only one at a time per profile: the
two share that profile's key and tunnel IP. Turn the macOS PAC off when using full
mode. In split mode the IPv6-leak question is moot — general traffic isn't tunnelled
at all.

(The old `MODE=full ./up.sh` flag is gone; set the mode when you create the profile,
or edit the `mode` column in `client/profiles.tsv` and delete the stale `.conf`.)

## Firewall

UDP 51820, open to the internet, managed by Terraform ([main.tf](main.tf)). Nothing
about it varies per session, so `up.sh` doesn't touch it.

**Exposing the port is the normal way to run WireGuard**, not a compromise:

- It never answers an unauthenticated packet. To a scanner the port is
  indistinguishable from closed or filtered — you don't show up as a WireGuard endpoint.
- The handshake carries a MAC keyed on the *server's* public key, checked before any
  Curve25519 work happens. Someone who doesn't already know that key can't make the box
  spend a single expensive crypto cycle, so handshake-flood attacks don't apply. A
  second cookie layer covers genuine load.
- Fixed cryptography, no negotiation, no certificate parsing — roughly 4k lines of
  kernel code against OpenVPN's hundreds of thousands. Most VPN CVEs historically live
  in exactly the parsing and negotiation complexity WireGuard doesn't have.
- The **pre-shared key** is mixed into every handshake on top of that.

Earlier versions locked ingress to your current public IP. That couldn't survive
multiple profiles: a security group filters on protocol and port, not on WireGuard
identity, so the rule is all-or-nothing across every peer and can't cover a friend
dialling in from their own changing address. What the lock bought was defense-in-depth
against a hypothetical zero-day in the handshake path, reachable only by someone who
already knew the server's public key. Nothing cryptographic depended on it.

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

**With several profiles the allowance is shared.** The 100 GB/month is account-wide, not
per profile, and a full-tunnel guest pushes all their browsing through the instance —
so a handed-out `full` config eats the budget considerably faster than your own split
usage does.

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
automatic security updates, a **WireGuard pre-shared key** (extra symmetric layer,
generated on-box → Secrets Manager, shared by every peer — it's a second factor on the
handshake, not a per-peer identity, so sharing it costs nothing), and the scoped IAM
policy (the instance can read/write only its own secrets and parameters; the peer list
it can only read).

Note that peers are **not** isolated from each other: `10.8.0.0/24` is a shared subnet
and the box forwards freely, so profiles can reach one another. Cryptokey routing still
stops anyone spoofing as somebody else, since the server pins each peer to its own
`/32`. If you ever hand a profile to someone you don't fully trust, add a
`FORWARD -i wg0 -o wg0 -j DROP` rule to the `PostUp` line in `user-data.sh.tftpl`.

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
