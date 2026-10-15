# ASM Tool — Manual Setup (gameberrylabs)

One-time setup on the dedicated scanner VM. Do this once; after that, `cronjob.sh`
runs unattended every week. Everything below assumes the VM is Ubuntu 22.04+ and
you're working as a user that has `sudo`.

Scope reminder: this tool only scans assets the company owns
(`gameberrylabs.com`, `superkinglabs.com`, their GCP projects, and the AWS
account used for S3/Route53). Don't point it at anything else.

---

## 0. Directory layout

Everything lives under `/home/kartik_patel_gameberrylabs_com/projects/asm`:

```
/home/kartik_patel_gameberrylabs_com/projects/asm/
  discovery.py
  asm.py
  common.py
  config.yaml
  cronjob.sh
  venv/                  <- python virtualenv
  secrets/
    gcp-sa.json
    notify-provider.yaml
  wordlists/
    raft-small-directories.txt
  output/                <- created automatically, one folder per run date
  logs/                  <- created automatically
```

You're already in `~/projects/asm` (`/home/kartik_patel_gameberrylabs_com/projects/asm`),
so no `sudo`/`chown` needed — it's your own home directory:

```bash
cd ~/projects/asm
mkdir -p secrets wordlists output logs
# copy/clone discovery.py, asm.py, common.py, config.yaml, cronjob.sh, requirements.txt
# into this directory, then:
chmod +x cronjob.sh
```

---

## 1. Base packages

```bash
sudo apt update
sudo apt install -y golang-go python3 python3-venv python3-pip git unzip nmap jq
```

Check Go version is 1.21+ (`go version`) — pdtm needs a recent Go. If apt's
version is old, install Go manually from https://go.dev/dl/ instead.

Add Go's bin dir to PATH for every shell (cron included), e.g. in `~/.bashrc`
and in a `/etc/profile.d/go.sh` file:

```bash
export PATH=$PATH:$(go env GOPATH)/bin
```

---

## 2. Install pdtm and all ProjectDiscovery tools

```bash
go install github.com/projectdiscovery/pdtm/cmd/pdtm@latest

# Installs/updates: subfinder, chaos-client, alterx, dnsx, cdncheck, tlsx,
# naabu, httpx, katana, nuclei, notify — all in one go. (cloudlist isn't
# used by this pipeline — GCP asset discovery uses gcloud + jq instead,
# see step 7 — but it's harmless if pdtm installs it anyway.)
pdtm -install-all

# Verify:
pdtm -list
```

If `pdtm -install-all` pulls in tools you don't need, that's fine — unused
binaries are harmless. The scripts only call the ones listed above.

Give `naabu` raw-socket capability so it doesn't need root in cron:

```bash
sudo setcap cap_net_raw,cap_net_admin+eip "$(which naabu)"
```

---

## 3. Install the non-PD tools: ffuf, gowitness

```bash
go install github.com/ffuf/ffuf/v2@latest
go install github.com/sensepost/gowitness@latest
```

Check gowitness's major version — `gowitness --help`. The code in `asm.py`
targets gowitness v3's `gowitness scan file -f <list> --screenshot-path <dir>`
syntax. If you installed v2, edit `take_screenshots()` in `asm.py` to use:

```
gowitness file -f <list> -P <dir>
```

(This is the one place in the whole tool where a tool's CLI syntax is
version-sensitive — everything else is stable across recent PD releases.)

`nmap` was already installed in step 1 via apt.

---

## 4. Python environment

```bash
cd /home/kartik_patel_gameberrylabs_com/projects/asm
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
deactivate
```

---

## 5. GCP access (for gcloud+jq asset discovery + GCS public-bucket checks)

Two ways to authenticate `gcloud`/`gsutil` as the scanner. Since this VM
*is itself* a GCP instance, **Option A is the right default** — no key file
to create, store, guard, or rotate. Use Option B only if you genuinely can't
attach a service account to this VM (shared box, managed by another team,
or you want the scanner portable to a non-GCP host later).

### Option A (recommended): attach the service account to this VM

1. Create the service account — no key generated:

```bash
gcloud iam service-accounts create asm-scanner --display-name="ASM Scanner"
```

2. Grant it **read-only** roles across every project in scope:

```bash
gcloud projects add-iam-policy-binding YOUR-PROJECT \
  --member="serviceAccount:asm-scanner@YOUR-PROJECT.iam.gserviceaccount.com" \
  --role="roles/viewer"
gcloud projects add-iam-policy-binding YOUR-PROJECT \
  --member="serviceAccount:asm-scanner@YOUR-PROJECT.iam.gserviceaccount.com" \
  --role="roles/storage.legacyBucketReader"
```
(`storage.legacyBucketReader` or broader is needed so `gsutil iam get` can
call `storage.buckets.getIamPolicy` on every bucket; add
`cloudsql.viewer` / `container.viewer` / `run.viewer` too if step 7's
smoke tests come back empty for those resource types.)

3. Attach that service account to this VM (requires a stop/start —
   you cannot change a running instance's service account in place):

```bash
gcloud compute instances stop gbl-security-workflow --zone=YOUR-ZONE
gcloud compute instances set-service-account gbl-security-workflow \
  --zone=YOUR-ZONE \
  --service-account=asm-scanner@YOUR-PROJECT.iam.gserviceaccount.com \
  --scopes=https://www.googleapis.com/auth/cloud-platform
gcloud compute instances start gbl-security-workflow --zone=YOUR-ZONE
```

The `cloud-platform` scope is required even though you're granting
fine-grained access via IAM roles above — without it, the VM's token is
scope-limited below whatever the IAM roles would otherwise allow.

4. Nothing else to configure. Once the VM restarts, `gcloud` and `gsutil`
   on this box automatically authenticate as `asm-scanner` via the
   metadata server — no login command, no key file. Confirm it:

```bash
gcloud auth list          # should show asm-scanner@..., marked as ACTIVE
gcloud config get-value account
```

5. Delete the `gcp.service_account_key` line from `config.yaml` (or just
   leave it — it's unused in this mode, nothing reads it).

6. If `gcp.projects` is left empty in `config.yaml`, the scripts call
   `gcloud projects list`, which needs the service account to have viewer
   access at the **organization** level — simpler to just list the
   project IDs explicitly in `config.yaml` if you only have a handful.

### Option B: downloaded JSON key (fallback only)

```bash
gcloud iam service-accounts keys create /home/kartik_patel_gameberrylabs_com/projects/asm/secrets/gcp-sa.json \
  --iam-account=asm-scanner@YOUR-PROJECT.iam.gserviceaccount.com
gcloud auth activate-service-account --key-file=/home/kartik_patel_gameberrylabs_com/projects/asm/secrets/gcp-sa.json
gcloud config set account asm-scanner@YOUR-PROJECT.iam.gserviceaccount.com
```

If you go this route, treat `gcp-sa.json` like a password: `chmod 600` it,
never commit it to git, and put a reminder somewhere to rotate it
periodically (`gcloud iam service-accounts keys list` to see its age,
`gcloud iam service-accounts keys create`/`delete` to rotate).

---

## 6. AWS access (S3 + Route53 only)

Create an IAM user (or role, if the VM is on EC2) with a read-only policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListAllMyBuckets",
        "s3:GetBucketAcl",
        "s3:GetBucketPolicy",
        "s3:GetBucketPolicyStatus",
        "s3:GetBucketLocation",
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "*"
    }
  ]
}
```

Install the AWS CLI and configure the profile named in `config.yaml`
(`aws.profile`, default is `default`):

```bash
aws configure --profile default
# Access Key ID / Secret Access Key / region / output format
```

boto3 (used directly by discovery.py for S3 + Route53) picks up the same
profile automatically.

---

## 7. GCP asset discovery: gcloud + jq (no cloudlist)

GCP asset inventory (`discover_gcp_assets()` in `discovery.py`) is done with
plain `gcloud ... --format=json | jq -c '...'` pipelines instead of
cloudlist, since cloudlist's own config format was causing problems in this
environment. There's no separate config file for this — it reuses the same
`gcp.projects` list and service-account auth from step 5. You just need
`jq` installed (already covered in step 1) and the service account to have
read access to the resource types being listed:

- Compute Engine instances — `roles/viewer` (step 5) covers this
- Load-balancer forwarding rules — `roles/viewer` covers this
- Cloud SQL instances — needs `roles/cloudsql.viewer` if `roles/viewer`
  alone doesn't return results in your org
- GKE clusters — needs `roles/container.viewer` if `roles/viewer` alone
  doesn't return results
- Cloud Run services — needs `roles/run.viewer` if `roles/viewer` alone
  doesn't return results

Grant whichever of those extra roles turns out to be needed:

```bash
gcloud projects add-iam-policy-binding YOUR-PROJECT \
  --member="serviceAccount:asm-scanner@YOUR-PROJECT.iam.gserviceaccount.com" \
  --role="roles/cloudsql.viewer"
```

Test each pipeline by hand once, as the scanning user, to make sure auth and
permissions are correct before trusting the cron job:

```bash
PROJECT="your-project-id"
gcloud compute instances list --project "$PROJECT" --format=json | jq -c '.[] | select([.networkInterfaces[]?.accessConfigs[]?.natIP | select(. != null)] | length > 0)'
gcloud compute forwarding-rules list --project "$PROJECT" --format=json | jq -c '.[] | select(.loadBalancingScheme == "EXTERNAL")'
gcloud sql instances list --project "$PROJECT" --format=json | jq -c '.[] | select(.settings.ipConfiguration.ipv4Enabled == true)'
gcloud container clusters list --project "$PROJECT" --format=json | jq -c '.[] | select(.privateClusterConfig.enablePrivateEndpoint != true)'
gcloud run services list --platform=managed --project "$PROJECT" --format=json | jq -c '.[]'
```

If a command errors with a permission or API-not-enabled message, either
grant the extra role above or enable the relevant API
(`gcloud services enable sqladmin.googleapis.com`, `container.googleapis.com`,
`run.googleapis.com`) — whichever services the company actually uses. It's
fine if some of these come back empty (e.g. no Cloud Run in use); the
function just returns nothing for that resource type and moves on.

Want a different or additional GCP resource type later? Copy one of the five
blocks in `discover_gcp_assets()` in `discovery.py`, change the `gcloud`
subcommand and the `jq` filter, and append the result the same way — no
other code needs to change.

---

## 8. notify provider config (Slack/Discord/Telegram/etc.)

Create `/home/kartik_patel_gameberrylabs_com/projects/asm/secrets/notify-provider.yaml`. Example for Slack:

```yaml
slack:
  - id: "asm-weekly"
    slack_channel: "#security-asm"
    slack_username: "ASM Bot"
    slack_webhook_url: "https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

Full format and other providers (Discord, Telegram, Teams, email) are
documented at https://github.com/projectdiscovery/notify — the tool is
pulled in by pdtm already, there's nothing extra to install.

If you don't want notifications yet, set `notify.enabled: false` in
`config.yaml` — the pipeline runs fine without it, it just won't ping anyone.

---

## 9. PostgreSQL

Easiest path: a local Postgres install on the same VM.

```bash
sudo apt install -y postgresql
sudo -u postgres psql -c "CREATE USER asm WITH PASSWORD 'CHANGE_ME';"
sudo -u postgres psql -c "CREATE DATABASE asm OWNER asm;"
```

Put the matching password into `config.yaml` under `postgres.password`.
Table creation is automatic — `common.init_db()` runs
`CREATE TABLE IF NOT EXISTS ...` for every table on each run, so there's no
separate migration step. If you ever change the schema in `common.py`'s
`SCHEMA` string, it's additive-only by design (new `CREATE TABLE IF NOT
EXISTS`); for column changes you'll need a manual `ALTER TABLE` once.

---

## 10. Wordlist for ffuf

Any directory wordlist works. A good small default (SecLists' raft-small):

```bash
curl -L -o /home/kartik_patel_gameberrylabs_com/projects/asm/wordlists/raft-small-directories.txt \
  https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/Web-Content/raft-small-directories.txt
```

Swap in a bigger list later by changing `paths.wordlist` in `config.yaml` —
no code change needed. Bigger wordlist = slower ffuf runs, so scale it with
`tuning.ffuf_threads` / `tuning.ffuf_timeout`.

---

### 10b. Sensitive-paths wordlist (secrets + API specs)

The exposure pass uses a second, small wordlist of ~160 high-value paths
(`.env`, `.git/config`, `swagger.json`, `openapi.json`, `/v3/api-docs`,
`/graphql`, `/actuator/env`, backups, terraform state, cloud key files...).
It ships with the project, so just make sure it's in place:

```bash
ls ~/projects/asm/wordlists/sensitive-paths.txt
```

Add your own paths (one per line, no leading slash) any time; no code change.

**What it reports and how to read it:** results land in the `exposures`
table and `output/<date>/exposures.jsonl`. Anything from the ffuf
`sensitive-path-exposed` check is "a path answered 200", so open the URL and
confirm (auto-calibration removes most soft-404s, not all). Nuclei hits carry
a template id and severity; `info` ones are mostly exposed API specs.
**Leaked values are redacted before saving** (first 4 chars + length), so
the database and JSONL files never hold a usable secret. If you find a real
one, open the URL yourself, then rotate it.

## 11. Nuclei templates (first-time pull)

`cronjob.sh` updates templates before every run, but pull them once manually
so the first run isn't starting from zero:

```bash
nuclei -update-templates
```

---

## 12. Chaos (optional)

Chaos is ProjectDiscovery's hosted recon dataset — free API key, but entirely
optional. If you don't set it up, `discovery.py` just skips it and relies on
subfinder + alterx/dnsx.

```bash
export CHAOS_KEY="your-key-here"
# add it to /etc/environment or the cron user's crontab so cron sees it too
```

---

## 13. Smoke-test everything before trusting the cron job

Run each tool once by hand to catch install/permission problems early:

```bash
subfinder -d gameberrylabs.com -silent | head
dnsx -l <(echo gameberrylabs.com) -a -resp -silent
httpx -l <(echo gameberrylabs.com) -silent
naabu -host gameberrylabs.com -top-ports 100 -silent
nuclei -u https://gameberrylabs.com -tags tech -silent
gowitness version
gcloud compute instances list --format=json | jq -c '.[] | select([.networkInterfaces[]?.accessConfigs[]?.natIP | select(. != null)] | length > 0)'
aws s3 ls --profile default
gcloud projects list
psql -h localhost -U asm -d asm -c '\dt'
```

Then run the two stages manually once, end to end:

```bash
source /home/kartik_patel_gameberrylabs_com/projects/asm/venv/bin/activate
export ASM_CONFIG=/home/kartik_patel_gameberrylabs_com/projects/asm/config.yaml
python3 /home/kartik_patel_gameberrylabs_com/projects/asm/discovery.py
python3 /home/kartik_patel_gameberrylabs_com/projects/asm/asm.py
```

Check `/home/kartik_patel_gameberrylabs_com/projects/asm/output/<today's date>/` for the JSONL files and
`/home/kartik_patel_gameberrylabs_com/projects/asm/logs/discovery.log` / `asm.log` for anything that logged an error.
A missing tool or bad credential logs a warning/error and the pipeline keeps
going — read the logs after the first run rather than assuming silence means
success.

---

## 14. Install the cron job

```bash
crontab -e
```

Add (Monday 3am, adjust as you like):

```
0 3 * * 1  /home/kartik_patel_gameberrylabs_com/projects/asm/cronjob.sh >> /home/kartik_patel_gameberrylabs_com/projects/asm/logs/cron.log 2>&1
```

Make sure `CHAOS_KEY` (if used) and `PATH` (Go bin dir) are available to cron
— cron runs with a minimal environment. Either set them in the crontab itself:

```
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/kartik_patel_gameberrylabs_com/go/bin
CHAOS_KEY=your-key-here
0 3 * * 1  /home/kartik_patel_gameberrylabs_com/projects/asm/cronjob.sh >> /home/kartik_patel_gameberrylabs_com/projects/asm/logs/cron.log 2>&1
```

---

## 15. Customizing later (no code changes needed for these)

- **Add a domain:** append it to `domains:` in `config.yaml`.
- **Add/remove a GCP project:** edit `gcp.projects` in `config.yaml`.
- **Speed up/slow down scans:** edit the `tuning:` block.
- **Change the wordlist:** point `paths.wordlist` at a different file.
- **Turn notifications off:** `notify.enabled: false`.
- **Change nuclei severity threshold:** `tuning.nuclei_severities`.
- **Tune the secrets/API-spec pass:** `tuning.exposure_tags`, `tuning.exposure_severities`, `paths.sensitive_wordlist`.

## 16. Hosting the dashboard as a persistent service

`python3 -m http.server` run by hand dies the moment you close that
terminal/SSH session. `asm-dashboard.service` wraps the same server in
systemd so it survives reboots and restarts itself if it ever crashes.

**Security note before you do this:** the dashboard shows open ports,
subdomains, and vulnerability findings for real infrastructure. The unit
file binds to `127.0.0.1` only — it is deliberately NOT reachable from the
network. You get to it via an SSH tunnel instead. Don't change the bind
address to `0.0.0.0` unless you've put real authentication (and ideally
TLS) in front of it first — see the note at the end of this section.

1. Put `dashboard.html` permanently inside the output directory (not
   copied in fresh each time — it only needs to exist there once):

```bash
cp ~/projects/asm/dashboard.html ~/projects/asm/output/dashboard.html
```

2. Install the systemd unit:

```bash
sudo cp ~/projects/asm/asm-dashboard.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now asm-dashboard
systemctl status asm-dashboard
```

3. Check it's actually listening (on the VM itself):

```bash
curl -s http://127.0.0.1:8080/dashboard.html | head -5
```

4. From your own laptop, open an SSH tunnel and browse through it:

```bash
ssh -L 8080:localhost:8080 kartik_patel_gameberrylabs_com@<vm-external-ip>
```

Then open `http://localhost:8080/dashboard.html` in your own browser. The
page stays open as long as the tunnel is connected; close the SSH session
and it stops being reachable, which is the point.

5. Logs, restart, stop:

```bash
journalctl -u asm-dashboard -f
sudo systemctl restart asm-dashboard
sudo systemctl stop asm-dashboard
```

6. **If you later want regular browser access without tunneling every
   time** (e.g. a few teammates need to check it): don't just reopen the
   port. Put nginx in front with HTTP basic auth and a firewall rule
   limiting source IPs (office/VPN range only), and keep the Python
   server bound to `127.0.0.1` as nginx's upstream. That's a reasonably
   small nginx config if/when you want it — ask and I'll write it, but it's
   a deliberate step up in complexity, not something to default into.

---

Things that DO need a small code edit (by design, kept in one place each):
- Switching gowitness v2 ↔ v3 syntax — one function in `asm.py` (`take_screenshots`).
- Adding a new Postgres table or column — `common.py`'s `SCHEMA` string.
- Adding a brand-new tool to the pipeline — one new function in `discovery.py`
  or `asm.py`, following the pattern of the existing ones (write input file →
  `common.run_cmd(...)` → parse JSON lines → return rows).