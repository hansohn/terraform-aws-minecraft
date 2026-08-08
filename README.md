<div align="center">
  <h3>terraform-aws-minecraft</h3>
  <p>On-demand, scale-to-zero Minecraft server on AWS Fargate</p>
  <p>
    <!-- Build Status -->
    <a href="https://actions-badge.atrox.dev/hansohn/terraform-aws-minecraft/goto?ref=main">
      <img src="https://img.shields.io/endpoint.svg?url=https%3A%2F%2Factions-badge.atrox.dev%2Fhansohn%2Fterraform-aws-minecraft%2Fbadge%3Fref%3Dmain&style=for-the-badge">
    </a>
    <!-- Github Tag -->
    <a href="https://gitHub.com/hansohn/terraform-aws-minecraft/tags/">
      <img src="https://img.shields.io/github/tag/hansohn/terraform-aws-minecraft.svg?style=for-the-badge">
    </a>
    <!-- License -->
    <a href="https://github.com/hansohn/terraform-aws-minecraft/blob/main/LICENSE">
      <img src="https://img.shields.io/github/license/hansohn/terraform-aws-minecraft.svg?style=for-the-badge">
    </a>
  </p>
</div>

## :open_book: Usage

This module runs a Minecraft server (Java or Bedrock) on **ECS Fargate that
scales to zero** — you only pay for compute while someone is actually playing.
When a player resolves the server's hostname, a Route53 DNS-query log triggers a
relay Lambda, which asks the **controller** to start the task; a watchdog sidecar
points DNS at the task on boot and shuts the server back down after a
configurable idle period. When the task stops, a second Lambda parks the A record
back on a placeholder so the hostname never resolves to a public IP AWS has
recycled to another account. World data persists on EFS between sessions.

The controller is the only role holding `ecs:UpdateService`, so every way in —
DNS, Discord, schedules — passes through the same decision. By default it says
yes to everything and the server behaves exactly as it always has; configure
`wake_windows` and it will only say yes during the hours you choose. See
"The wake gate".

Because Route53 public-zone query logging must live in `us-east-1`, the module
manages a dedicated `us-east-1` provider internally for that plumbing while the
server itself runs in whatever region you point the default `aws` provider at.

```hcl
provider "aws" {
  region = "us-west-2"
}

module "minecraft" {
  source = "hansohn/minecraft/aws"

  domain_name = "minecraft.example.com"

  # Modded server for a small group on Fargate Spot
  task_cpu    = 2048
  task_memory = 16384
  java_memory = "10G"

  minecraft_env = {
    TYPE       = "AUTO_CURSEFORGE"
    CF_API_KEY = "your-curseforge-api-key"
    CF_SLUG    = "all-the-mods-9"
  }
}
```

After `apply`, delegate the subdomain to Route53 by adding the `name_servers`
output as `NS` records at your parent domain's DNS provider (e.g. Cloudflare),
**DNS-only / unproxied**. Players then connect to `domain_name`.

If the parent domain is on Cloudflare, that delegation can be applied rather
than clicked — one `NS` record per Route53 name server:

```hcl
resource "cloudflare_dns_record" "minecraft_ns" {
  for_each = toset(module.minecraft.name_servers)

  zone_id = var.cloudflare_zone_id # parent domain's zone ID, not a secret
  name    = module.minecraft.server_address
  type    = "NS"
  content = each.value
  ttl     = 3600
}
```

The resource is `cloudflare_dns_record` on provider v5 (it was `cloudflare_record`
before). Verify with `dig NS minecraft.example.com +short`, which should return
the four Route53 name servers.

### Optional features

```hcl
module "minecraft" {
  source      = "hansohn/minecraft/aws"
  domain_name = "minecraft.example.com"

  # Let Bedrock clients join a Java server via the Geyser plugin (opens UDP 19132).
  # Install Geyser/Floodgate from GeyserMC's download API, not Modrinth — see
  # "Geyser on Paper" below.
  enable_geyser = true

  # ...or run a native Bedrock server instead of Java (UDP 19132):
  # server_edition = "bedrock"

  # Restrict who can connect (default is open to the internet).
  allowed_cidrs = ["203.0.113.4/32"]

  # Open extra ports for plugins that need their own listener — e.g. Simple
  # Voice Chat (install via MODRINTH_PROJECTS). Opened to the same allowed_cidrs
  # as the game port.
  additional_ports = [{ port = 24454, protocol = "udp" }]

  # Point-in-time EFS backups (opt-in); enable and optionally tune retention.
  enable_backups        = true
  backup_retention_days = 14

  # Admin the running container via ECS Exec (IAM-gated, no inbound port).
  enable_ecs_exec = true

  # Seed plugin config files onto the EFS volume (written only if absent).
  plugin_configs = {
    "plugins/DiscordSRV/config.yml" = file("${path.module}/discordsrv.yml")
  }

  # Repost start/stop notifications to Discord (pass the URL as a secret).
  # discord_webhook_url = var.discord_webhook_url

  # Add a /minecraft slash command that wakes the server (see below).
  # discord_application_public_key = "abc123..."
  # discord_guild_id               = "112233445566778899"
  # discord_privileged_role_id     = "998877665544332211"

  # Only let DNS lookups wake the server during these hours (see "The wake
  # gate"). Empty windows, the default, means no restriction.
  # wake_default_mode = "schedule"
  # wake_timezone     = "America/Los_Angeles"
  # wake_windows = [
  #   { days = ["mon", "tue", "wed", "thu"], start = "15:30", end = "20:30" },
  #   { days = ["sat", "sun"],               start = "09:00", end = "22:00" },
  # ]

  # Also stop a server that's already running when its window closes, warning
  # players in-game first (see "Curfews and stops").
  # enable_curfew          = true
  # curfew_warning_minutes = 10

  # Remove the DNS wake path entirely, so only Discord can start the server.
  # enable_dns_wake = false

  # Deploy into an existing VPC instead of creating one. Subnets must be
  # PUBLIC (route to an IGW) and in distinct AZs.
  # create_vpc = false
  # vpc_id     = "vpc-0123456789abcdef0"
  # subnet_ids = ["subnet-aaa", "subnet-bbb"]
}
```

> **Upgrading to v0.4.0:** `enable_bedrock` was renamed to **`enable_geyser`**
> to distinguish the Java-side Geyser add-on from running a native Bedrock
> server (`server_edition = "bedrock"`). Rename the input when you upgrade.

### Sizing

`task_cpu` / `task_memory` are Fargate task sizes; `java_memory` is the JVM heap
inside it. Keep the heap well under the task memory — the JVM needs metaspace
and native memory on top, and the watchdog sidecar shares the task.

| Server | `task_cpu` | `task_memory` | `java_memory` |
|---|---|---|---|
| Vanilla / Paper, few players | 2048 | 4096 | `3G` |
| Paper + plugin stack (Geyser, ViaVersion, voice chat) | 2048 | 8192 | `6G` |
| Modded (Forge/Fabric modpack) | 2048 | 16384 | `10G` |

Measured on a real deployment: Paper with Geyser, Floodgate, ViaVersion,
ViaBackwards, and Simple Voice Chat sat at **~82% memory on 4096/3G** — fine
solo, thin for a group — so 8192/6G is the better starting point for that stack.
CPU is rarely the constraint: 2048 idles around 6% and spikes only at boot. On
Spot the extra memory costs well under $1/month at typical play time.

### Geyser on Paper

Geyser and Floodgate let Bedrock clients join a Java server. **Install them from
GeyserMC's download API rather than Modrinth** — Floodgate publishes no
paper/spigot builds on Modrinth at all (fabric/neoforge only), and GeyserMC lets
Hangar's Paper version tags go stale, so the vendor API is the only source that
reliably tracks the newest Minecraft:

```hcl
enable_geyser = true

minecraft_env = {
  TYPE = "PAPER"

  PLUGINS = join(",", [
    "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot",
    "https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot",
  ])

  # ViaVersion + ViaBackwards let clients on older Minecraft versions join a
  # server running the newest release without updating first. Geyser also asks
  # for ViaVersion. These do publish Paper builds on Modrinth.
  MODRINTH_PROJECTS = "simple-voice-chat,viaversion,viabackwards"
}

# Simple Voice Chat needs its own UDP listener.
additional_ports = [{ port = 24454, protocol = "udp" }]
```

### Restricting who can join

`allowed_cidrs` narrows network access, but it's blunt — players' home IPs
change. The practical control is Minecraft's own whitelist, set through
`minecraft_env`:

```hcl
minecraft_env = {
  ENABLE_WHITELIST = "TRUE"
  WHITELIST        = "player1,player2,player3"
  ONLINE_MODE      = "TRUE" # verify accounts against Mojang/Microsoft auth
}
```

Keep `ONLINE_MODE = "TRUE"` unless you have a specific reason not to — with it
off, anyone can connect using any username, and the whitelist stops meaning
anything.

With `enable_ecs_exec = true`, open a shell — or drive the container's built-in
RCON — on the running task without any inbound port (access is IAM-gated over
SSM Session Manager):

```sh
TASK=$(aws ecs list-tasks --cluster minecraft --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster minecraft --task "$TASK" \
  --container minecraft --interactive --command "rcon-cli"
```

The AWS CLI needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) installed locally.

`plugin_configs` seeds files onto the EFS `/data` volume so plugins (e.g. a
Discord bridge like DiscordSRV) start with a config already in place. A one-shot
init container writes each file **only if it does not already exist**, so edits
made in-game or by the plugin survive restarts — to re-seed a file, delete it
from EFS first. Keys are paths relative to `/data`.

> :warning: File contents are stored in the ECS task definition in plaintext and
> visible to anyone with `ecs:DescribeTaskDefinition`. **Do not put secrets**
> (bot tokens, passwords) in `plugin_configs` — seed the non-secret config and
> supply secrets through the plugin's own secret mechanism.

### Discord slash command

Waking the server by DNS query is invisible to players — the hostname resolves
to a placeholder until the task is up, so a first connection attempt just fails
and there's no way to tell "starting" from "broken". Setting
`discord_application_public_key` publishes a `/minecraft` command instead:

| Command | Who | What |
| --- | --- | --- |
| `/minecraft status` | anyone | asleep / starting / up, plus the gate state |
| `/minecraft start` | privileged | wakes the server (idempotent), bypassing the gate |
| `/minecraft stop [minutes]` | privileged | stops now, or warns and stops later |
| `/minecraft gate …` | privileged | see "The wake gate" below |

"Privileged" means holding `discord_privileged_role_id`. Leave it empty and
guild membership alone is enough, which is how the command behaved before
0.8.0 — so upgrading doesn't lock anyone out. Gate operations are nested under
a subcommand group deliberately: `block` means a great many things on a
Minecraft server and none of them are this.

Readiness still arrives through the existing `discord_webhook_url`
notification, so set both to close the loop.

Three one-time manual steps, since Terraform can't create the Discord app:

1. Create an application at the [Discord Developer Portal](https://discord.com/developers/applications).
   Copy **Public Key** into `discord_application_public_key` and apply.
2. Register the command, using the application ID and a bot token from the same app:

   ```sh
   curl -X PUT -H "Authorization: Bot $BOT_TOKEN" -H "Content-Type: application/json" \
     "https://discord.com/api/v10/applications/$APP_ID/commands" \
     -d '[{"name":"minecraft","description":"Control the Minecraft server","options":[
           {"type":1,"name":"start","description":"Wake the server"},
           {"type":1,"name":"status","description":"Check whether the server is up"},
           {"type":1,"name":"stop","description":"Stop the server","options":[
             {"type":4,"name":"minutes","description":"Warn players, then stop after this many minutes","required":false}]},
           {"type":2,"name":"gate","description":"Control when DNS lookups may wake the server","options":[
             {"type":1,"name":"enable","description":"DNS lookups may start the server"},
             {"type":1,"name":"disable","description":"DNS lookups may not start the server"},
             {"type":1,"name":"schedule","description":"Follow the configured hours"},
             {"type":1,"name":"allow","description":"Temporarily allow starts","options":[
               {"type":4,"name":"minutes","description":"How long, in minutes","required":true}]},
             {"type":1,"name":"block","description":"Temporarily refuse starts","options":[
               {"type":4,"name":"minutes","description":"How long, in minutes","required":true}]}]}]}]'
   ```

3. Paste the `discord_interactions_url` output into the portal as the
   **Interactions Endpoint URL**. Discord probes it with a deliberately invalid
   signature and only saves the URL if the endpoint rejects it.

The Function URL is public and unauthenticated — Discord can't sign with SigV4 —
so the Ed25519 signature check in `lambda/discord_command.py` is what guards it.
Requests without a valid signature over the timestamp and body get a 401, and
timestamps older than five minutes are refused to close the replay window. Set
`discord_guild_id` to additionally pin the command to one server.

### The wake gate

Wake-on-DNS has no notion of *who* asked. The subscription filter uses an empty
`filter_pattern`, so it matches every event in the query log, and the relay
never reads the event it was handed. Any resolver reaching the zone asks for a
start: any record type, any name under the zone, including ones that don't
exist.

In practice that means DNS scanners. A zone that only ever sees a handful of
real queries a week will still get probed — typically `SOA` and `A` lookups from
datacenter IPs with no `SRV` lookup, which is the tell that no Minecraft client
was involved. Filtering by record type does not help: a scanner's plain `A`
lookup is indistinguishable from a player's.

So the decision is made on *time and policy* instead, in one place. Every wake
path — the DNS relay, the Discord command, the curfew schedules — invokes the
**controller** Lambda, which is the only role in the module holding
`ecs:UpdateService`. The others cannot reach ECS at all, so the gate is not an
honour system a future edit can forget to consult.

The gate has three modes, and governs **the DNS path only**:

| Mode | Effect |
| --- | --- |
| `enable` | DNS lookups may start the server (the default; today's behaviour) |
| `disable` | DNS lookups may not — a kill switch |
| `schedule` | DNS lookups may, but only inside `wake_windows` |

`/minecraft start` and `/minecraft stop` are privileged and **not** gated. That
is what stops Discord being a way around the schedule: unprivileged users cannot
start the server at all, so there is nothing to gate.

```hcl
wake_default_mode = "schedule"
wake_timezone     = "America/Los_Angeles"
wake_windows = [
  { days = ["mon", "tue", "wed", "thu"], start = "15:30", end = "20:30" },
  { days = ["fri"],                      start = "15:30", end = "22:00" },
  { days = ["sat", "sun"],               start = "09:00", end = "22:00" },
]
```

Windows are evaluated with Python's `zoneinfo`, so daylight saving is applied
for you and the hours do not drift twice a year. A window whose `end` is earlier
than its `start` wraps past midnight and belongs to its **start** day, so
`{ days = ["fri"], start = "22:00", end = "02:00" }` runs into Saturday morning
without needing a Saturday entry.

**`wake_windows = []` means no restriction**, which is what keeps all of this
opt-in — with the defaults, the module behaves exactly as it did before.

Runtime changes go through Discord, and land in an SSM parameter rather than a
`terraform apply`:

```
/minecraft gate schedule       follow the windows
/minecraft gate disable        nothing may wake it
/minecraft gate allow 60       one more hour, whatever the schedule says
/minecraft gate block 30       no play for half an hour
```

`allow` and `block` expire on their own; `gate <mode>` persists until changed.
None of this requires Discord, though — the parameter is just JSON, and the
`gate_parameter_name` output tells you where it is:

```sh
aws ssm put-parameter --name "$(terraform output -raw gate_parameter_name)" \
  --overwrite --value '{"version":1,"mode":"disable"}'
```

Failures fail **closed**: an unusable `wake_timezone` or an unreadable parameter
denies the start and logs why, because failing open silently voids a curfew
while failing closed is recoverable in one command.

`enable_dns_wake = false` is the deploy-time counterpart — it removes the relay
and subscription filter entirely, rather than shutting them at runtime. Use it
for a Discord-only deployment. Route53 query logging stays on either way; it is
the only record of who is resolving the hostname, and what makes an unexpected
start attributable after the fact:

```sh
aws logs filter-log-events --region us-east-1 \
  --log-group-name "/aws/route53/$DOMAIN_NAME" \
  --start-time $(( ($(date +%s) - 86400) * 1000 )) \
  --query 'events[].message' --output text
```

> :warning: With `enable_dns_wake = false` and no Discord public key, nothing
> starts the server automatically. Invoke the controller directly — see the
> `controller_function_name` output. The gate still applies to that path.

### Curfews and stops

The gate only refuses to *start*. A session already running when the window
closes carries on until the players leave and `shutdown_minutes` expires. That
is often enough — they simply can't get back in — but `enable_curfew` makes the
boundary real:

```hcl
enable_curfew          = true
curfew_warning_minutes = 10
```

Schedules are derived from `wake_windows`, so there is only ever one definition
of "when are we open". At the warning mark players are told in-game and the
notification goes out over SNS (so email, and Discord if `discord_webhook_url`
is set); at the close the controller scales the service to zero.

In-game warnings come from an **announcer sidecar** added to the task. In
`awsvpc` mode every container shares one network namespace, so it reaches RCON
on `localhost` — nothing is exposed to the VPC, there is no port to open and no
VPC-attached Lambda. It carries its own copy of the window closes and needs no
AWS credentials at all.

It is off by default because it disconnects players mid-session. The itzg image
handles `SIGTERM` and saves the world, so there is no data loss, but the exit is
abrupt.

Ad-hoc stops use the same machinery, for maintenance:

```
/minecraft stop 10     warn, then stop in ten minutes
/minecraft stop        stop now
```

> :information_source: The sidecar only knows about *scheduled* closes, so an
> ad-hoc `/minecraft stop 10` warns through Discord and email but not in-game.
> If you want players warned in-game too, say so first over RCON — see
> "Moderating players" below.

### Moderating players

This module deliberately has no player-moderation commands: banning, kicking and
whitelisting all need RCON, and the Minecraft ecosystem already solves it better
than a Lambda could. **DiscordSRV's console channel** gives you the lot from a
phone with no AWS infrastructure — set `DiscordConsoleChannelId` to a private,
admin-only channel and messages sent there run as console commands:

```
ban SomeKid griefing
kick SomeKid
whitelist add NewKid
fwhitelist add BedrockKid     # Floodgate — Bedrock players are separate
```

Three things to know. It is **full console access**, not scoped to moderation,
so that channel must be private (`DiscordConsoleChannelBlacklistedCommands`
narrows it). The **bot token is a secret and must not go in `plugin_configs`** —
those contents sit in the task definition in plaintext; seed everything else and
set the token once by hand, where it persists on EFS. And Bedrock players joining
through Geyser need Floodgate's own whitelist, separate from the vanilla one.

Failing that, `enable_ecs_exec = true` gives you `rcon-cli` from a terminal
without opening a port at all — see "Restricting who can join" above.

### Using with Terragrunt

Pin an **exact** module version. Terragrunt's `tfr://` getter passes the
constraint straight to the registry's download endpoint, which wants a concrete
version — a range like `~> 0.7.0` resolves fine from a warm `.terragrunt-cache`
locally but 404s on a clean CI runner:

```hcl
terraform {
  source = "tfr:///hansohn/minecraft/aws?version=0.7.0"
}
```

## :sparkles: Examples

Please see the sample set of examples below for a better understanding of implementation

- [Complete](examples/complete) - Complete Example

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_additional_ports"></a> [additional\_ports](#input\_additional\_ports) | Extra ports to open on the task security group and map into the container, for plugins that need their own listener (e.g. Simple Voice Chat on UDP 24454, dynmap on TCP 8123). Each entry opens one ingress rule per allowed\_cidrs block. protocol must be "tcp" or "udp". | <pre>list(object({<br/>    port     = number<br/>    protocol = string<br/>  }))</pre> | `[]` | no |
| <a name="input_allowed_cidrs"></a> [allowed\_cidrs](#input\_allowed\_cidrs) | CIDR blocks allowed to reach the game port(s). Defaults to open (0.0.0.0/0); narrow to known player IPs to lock the server down. Note the port must stay reachable from wherever players connect for the wake-on-DNS launcher to trigger. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_backup_retention_days"></a> [backup\_retention\_days](#input\_backup\_retention\_days) | Days to retain each EFS backup recovery point when enable\_backups is true. | `number` | `35` | no |
| <a name="input_backup_schedule"></a> [backup\_schedule](#input\_backup\_schedule) | Cron schedule (UTC) for EFS backups when enable\_backups is true. Defaults to daily at 05:00 UTC. | `string` | `"cron(0 5 * * ? *)"` | no |
| <a name="input_bedrock_port"></a> [bedrock\_port](#input\_bedrock\_port) | UDP port opened for Bedrock clients via the Geyser plugin. Only used on a java server with enable\_geyser = true. | `number` | `19132` | no |
| <a name="input_config_seed_image"></a> [config\_seed\_image](#input\_config\_seed\_image) | Container image for the init container that seeds plugin\_configs onto the EFS volume. Only used when plugin\_configs is non-empty; needs a shell and base64 (busybox suffices). | `string` | `"public.ecr.aws/docker/library/busybox:stable"` | no |
| <a name="input_cpu_architecture"></a> [cpu\_architecture](#input\_cpu\_architecture) | Task CPU architecture. Fargate Spot only supports X86\_64; use ARM64 only with use\_spot = false. | `string` | `"X86_64"` | no |
| <a name="input_create_vpc"></a> [create\_vpc](#input\_create\_vpc) | Create a dedicated VPC (with public subnets, IGW, and routing). Set false to deploy into an existing VPC via vpc\_id + subnet\_ids. | `bool` | `true` | no |
| <a name="input_curfew_announcer_image"></a> [curfew\_announcer\_image](#input\_curfew\_announcer\_image) | Image for the announcer sidecar that issues in-game warnings over RCON on localhost. Empty uses the same image as the server, which already ships rcon-cli — so no extra pull and no image to build. Ignored unless enable\_curfew is true. | `string` | `""` | no |
| <a name="input_curfew_warning_minutes"></a> [curfew\_warning\_minutes](#input\_curfew\_warning\_minutes) | How long before a curfew stop to start warning players, in-game via the announcer sidecar and in Discord via the SNS topic. Also the default lead time for an ad-hoc `/minecraft stop` with no argument-supplied delay. Ignored unless enable\_curfew is true. | `number` | `10` | no |
| <a name="input_discord_application_public_key"></a> [discord\_application\_public\_key](#input\_discord\_application\_public\_key) | Discord application public key (Developer Portal > General Information). When set, a Lambda Function URL is published as the app's interactions endpoint, backing a /minecraft slash command that starts the server and reports status. Not a secret — it only verifies Discord's request signatures. | `string` | `""` | no |
| <a name="input_discord_guild_id"></a> [discord\_guild\_id](#input\_discord\_guild\_id) | Restrict the /minecraft slash command to a single Discord server (guild) ID. Empty allows any guild the app is installed in. Ignored unless discord\_application\_public\_key is set. | `string` | `""` | no |
| <a name="input_discord_privileged_role_id"></a> [discord\_privileged\_role\_id](#input\_discord\_privileged\_role\_id) | Discord role ID allowed to run the privileged /minecraft subcommands (start, stop, and the gate group). Empty keeps the pre-0.8.0 behaviour where guild membership alone is enough, so upgrading does not lock existing users out. Ignored unless discord\_application\_public\_key is set. | `string` | `""` | no |
| <a name="input_discord_webhook_url"></a> [discord\_webhook\_url](#input\_discord\_webhook\_url) | Discord channel webhook URL. When set, a Lambda subscribes to the SNS topic and reposts server start/stop notifications to Discord. Pass via TF\_VAR\_discord\_webhook\_url; keep it out of version control. | `string` | `""` | no |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | Fully-qualified server hostname, also created as a Route53 public hosted zone (e.g. "minecraft.hansohn.io"). The parent domain's DNS provider (Cloudflare) must delegate this subdomain to the zone's name servers — see the name\_servers output. | `string` | n/a | yes |
| <a name="input_efs_throughput_mode"></a> [efs\_throughput\_mode](#input\_efs\_throughput\_mode) | EFS throughput mode. Use "bursting" or "elastic"; avoid "provisioned" to keep costs down. | `string` | `"bursting"` | no |
| <a name="input_enable_backups"></a> [enable\_backups](#input\_enable\_backups) | Create an AWS Backup plan + vault that takes point-in-time backups of the EFS world data. EFS itself has no restore points; enabling this guards against corruption, griefing, or accidental deletion (billed per GB retained). | `bool` | `false` | no |
| <a name="input_enable_curfew"></a> [enable\_curfew](#input\_enable\_curfew) | Stop a RUNNING server when its wake\_window closes, rather than only refusing to start a new one. Off by default because it disconnects players mid-session — the itzg image handles SIGTERM and saves the world, so there is no data loss, but the exit is abrupt. Requires wake\_windows to be non-empty. Also adds the announcer sidecar so players get in-game warning first. | `bool` | `false` | no |
| <a name="input_enable_dns_wake"></a> [enable\_dns\_wake](#input\_enable\_dns\_wake) | Build the DNS wake path: a Route53 query-log subscription filter and the relay Lambda that forwards to the controller. Waking on DNS is unauthenticated by construction — the filter matches every query log event and the relay inspects none of it, so automated scanners reach the controller as readily as players do (the gate is what decides whether they get a server). Set to false to drop that path entirely, leaving the Discord /minecraft command as the way in; with neither enabled the service starts only via the controller (see the controller\_function\_name output). Route53 query logging stays on either way, so unexpected starts remain attributable. | `bool` | `true` | no |
| <a name="input_enable_ecs_exec"></a> [enable\_ecs\_exec](#input\_enable\_ecs\_exec) | Enable ECS Exec on the task so operators can open a shell (or run rcon-cli) inside the running container via `aws ecs execute-command`. Access is gated entirely by IAM over SSM Session Manager — no inbound port is opened. Grants the task role ssmmessages permissions. | `bool` | `false` | no |
| <a name="input_enable_geyser"></a> [enable\_geyser](#input\_enable\_geyser) | On a java server, also open the Bedrock UDP port (bedrock\_port) for the Geyser plugin so Bedrock clients can join. For a native Bedrock server use server\_edition = "bedrock" instead. | `bool` | `false` | no |
| <a name="input_java_memory"></a> [java\_memory](#input\_java\_memory) | Heap size passed to itzg/minecraft-server via MEMORY. Keep it below task\_memory to leave headroom for JVM metaspace/native memory and the watchdog sidecar. | `string` | `"10G"` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | CloudWatch Logs retention for container, DNS query, and Lambda logs. | `number` | `7` | no |
| <a name="input_minecraft_env"></a> [minecraft\_env](#input\_minecraft\_env) | Extra environment variables for itzg/minecraft-server (e.g. TYPE, VERSION, MODPACK, AUTO\_CURSEFORGE settings, CF\_API\_KEY). Merged over the EULA/MEMORY defaults. | `map(string)` | `{}` | no |
| <a name="input_minecraft_image"></a> [minecraft\_image](#input\_minecraft\_image) | Minecraft server container image. Empty selects the edition default: itzg/minecraft-server for java, itzg/minecraft-bedrock-server for bedrock. | `string` | `""` | no |
| <a name="input_minecraft_port"></a> [minecraft\_port](#input\_minecraft\_port) | TCP port the Java server listens on. Ignored when server\_edition = "bedrock" (native Bedrock uses UDP 19132). | `number` | `25565` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix applied to all resources. | `string` | `"minecraft"` | no |
| <a name="input_notification_email"></a> [notification\_email](#input\_notification\_email) | If set, subscribes this email address to the SNS topic for start/stop notifications. | `string` | `""` | no |
| <a name="input_plugin_configs"></a> [plugin\_configs](#input\_plugin\_configs) | Files to seed onto the EFS /data volume before the server starts, keyed by path relative to /data (e.g. "plugins/DiscordSRV/config.yml"); values are the file contents. A lightweight init container writes each file only if it does not already exist, so the server/plugins can edit it afterward (delete the file on EFS to re-seed). Contents are stored in the task definition in plaintext — do NOT put secrets (bot tokens, passwords) here; reference those from the plugin config via its own secret mechanism. | `map(string)` | `{}` | no |
| <a name="input_server_edition"></a> [server\_edition](#input\_server\_edition) | Minecraft edition to run. "java" listens on TCP (minecraft\_port); "bedrock" runs a native Bedrock server on UDP 19132. Drives the game port protocol and the default container image. | `string` | `"java"` | no |
| <a name="input_shutdown_minutes"></a> [shutdown\_minutes](#input\_shutdown\_minutes) | Idle time (minutes) with no players before the watchdog scales the service to zero. | `number` | `20` | no |
| <a name="input_startup_minutes"></a> [startup\_minutes](#input\_startup\_minutes) | Grace period (minutes) the watchdog waits for a first connection before it may shut the server down. | `number` | `10` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | Existing subnet IDs when create\_vpc = false. Must be PUBLIC (route to an internet gateway) — the task needs a public IP for wake-on-DNS — and each in a distinct AZ (EFS allows one mount target per AZ). Ignored when create\_vpc = true. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags applied to all resources. | `map(string)` | `{}` | no |
| <a name="input_task_cpu"></a> [task\_cpu](#input\_task\_cpu) | Fargate task vCPU units (2048 = 2 vCPU). Must be a valid Fargate CPU/memory pairing. | `number` | `2048` | no |
| <a name="input_task_memory"></a> [task\_memory](#input\_task\_memory) | Fargate task memory in MiB (16384 = 16 GB). | `number` | `16384` | no |
| <a name="input_use_spot"></a> [use\_spot](#input\_use\_spot) | Run the task on Fargate Spot (much cheaper; rare interruptions just restart the server). Spot is x86 only. | `bool` | `true` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | CIDR block for the VPC. Only used when create\_vpc = true. | `string` | `"10.100.0.0/24"` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | Existing VPC to deploy into when create\_vpc = false. Ignored when create\_vpc = true. | `string` | `""` | no |
| <a name="input_wake_default_mode"></a> [wake\_default\_mode](#input\_wake\_default\_mode) | Initial gate mode seeded into the SSM parameter: "enable" (DNS queries may start the task), "disable" (they may not), or "schedule" (they may, but only inside wake\_windows). NOTE: the parameter carries ignore\_changes on its value because Discord and the CLI mutate it, so this is a CREATE-TIME setting only — changing it later will not update an existing parameter. Use the /minecraft gate subcommands or `aws ssm put-parameter --overwrite` instead. | `string` | `"enable"` | no |
| <a name="input_wake_timezone"></a> [wake\_timezone](#input\_wake\_timezone) | IANA timezone the wake\_windows are expressed in, e.g. "America/Los\_Angeles". Handled by Python's zoneinfo, so daylight saving transitions are applied automatically and windows do not drift. Only used when the gate mode is "schedule". | `string` | `"UTC"` | no |
| <a name="input_wake_windows"></a> [wake\_windows](#input\_wake\_windows) | Hours during which DNS queries may start the task, in wake\_timezone, when the gate mode is "schedule". Days are mon..sun; start/end are zero-padded 24h "HH:MM". A window whose end is earlier than its start wraps past midnight and belongs to its START day. EMPTY MEANS NO RESTRICTION, which is what keeps this opt-in and leaves existing deployments unchanged. | <pre>list(object({<br/>    days  = list(string)<br/>    start = string<br/>    end   = string<br/>  }))</pre> | `[]` | no |
| <a name="input_watchdog_image"></a> [watchdog\_image](#input\_watchdog\_image) | Watchdog sidecar image that points DNS at the task on boot and scales the service to zero when idle. | `string` | `"doctorray/minecraft-ecsfargate-watchdog:latest"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_controller_function_name"></a> [controller\_function\_name](#output\_controller\_function\_name) | Lambda that owns starting and stopping the service — the only role holding ecs:UpdateService. Start the server without Discord or a DNS query: aws lambda invoke --function-name <this> --payload '{"action":"start","source":"cli"}' /dev/stdout. The gate still applies to this path, so a start while the mode is "disable" is refused; change the gate first via gate\_parameter\_name. |
| <a name="output_discord_interactions_url"></a> [discord\_interactions\_url](#output\_discord\_interactions\_url) | Lambda Function URL to paste into the Discord Developer Portal as the app's Interactions Endpoint URL. Empty unless discord\_application\_public\_key is set. |
| <a name="output_ecs_cluster_name"></a> [ecs\_cluster\_name](#output\_ecs\_cluster\_name) | ECS cluster name. |
| <a name="output_ecs_service_name"></a> [ecs\_service\_name](#output\_ecs\_service\_name) | ECS service name. |
| <a name="output_efs_id"></a> [efs\_id](#output\_efs\_id) | EFS file system ID holding the world data. |
| <a name="output_gate_parameter_name"></a> [gate\_parameter\_name](#output\_gate\_parameter\_name) | SSM parameter holding the runtime wake-gate state. Change the mode without Discord: aws ssm put-parameter --name <this> --overwrite --value '{"version":1,"mode":"disable"}'. |
| <a name="output_hosted_zone_id"></a> [hosted\_zone\_id](#output\_hosted\_zone\_id) | Route53 hosted zone ID. |
| <a name="output_name_servers"></a> [name\_servers](#output\_name\_servers) | Route53 name servers for the delegated zone. Create NS records for this subdomain at your parent-domain DNS provider (Cloudflare), DNS-only / unproxied. |
| <a name="output_server_address"></a> [server\_address](#output\_server\_address) | Hostname players connect to. |
| <a name="output_sns_topic_arn"></a> [sns\_topic\_arn](#output\_sns\_topic\_arn) | SNS topic ARN for start/stop notifications. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC ID hosting the server (created or caller-supplied). |
<!-- END_TF_DOCS -->

<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
