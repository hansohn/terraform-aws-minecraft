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
When a
player resolves the server's hostname, a Route53 DNS-query log triggers a Lambda
that starts the task; a watchdog sidecar points DNS at the task on boot and
shuts the server back down after a configurable idle period. World data persists
on EFS between sessions.

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

### Optional features

```hcl
module "minecraft" {
  source      = "hansohn/minecraft/aws"
  domain_name = "minecraft.example.com"

  # Let Bedrock clients join a Java server via the Geyser plugin (opens UDP 19132).
  enable_geyser = true
  minecraft_env = { TYPE = "PAPER", MODRINTH_PROJECTS = "geyser,floodgate" }

  # ...or run a native Bedrock server instead of Java (UDP 19132):
  # server_edition = "bedrock"

  # Restrict who can connect (default is open to the internet).
  allowed_cidrs = ["203.0.113.4/32"]

  # Point-in-time EFS backups (opt-in); enable and optionally tune retention.
  enable_backups        = true
  backup_retention_days = 14

  # Admin the running container via ECS Exec (IAM-gated, no inbound port).
  enable_ecs_exec = true

  # Repost start/stop notifications to Discord (pass the URL as a secret).
  # discord_webhook_url = var.discord_webhook_url

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

With `enable_ecs_exec = true`, open a shell — or drive the container's built-in
RCON — on the running task without any inbound port (access is IAM-gated over
SSM Session Manager):

```sh
TASK=$(aws ecs list-tasks --cluster minecraft --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster minecraft --task "$TASK" \
  --container minecraft --interactive --command "rcon-cli"
```

The AWS CLI needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) installed locally.

## :sparkles: Examples

Please see the sample set of examples below for a better understanding of implementation

- [Complete](examples/complete) - Complete Example

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_cidrs"></a> [allowed\_cidrs](#input\_allowed\_cidrs) | CIDR blocks allowed to reach the game port(s). Defaults to open (0.0.0.0/0); narrow to known player IPs to lock the server down. Note the port must stay reachable from wherever players connect for the wake-on-DNS launcher to trigger. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_backup_retention_days"></a> [backup\_retention\_days](#input\_backup\_retention\_days) | Days to retain each EFS backup recovery point when enable\_backups is true. | `number` | `35` | no |
| <a name="input_backup_schedule"></a> [backup\_schedule](#input\_backup\_schedule) | Cron schedule (UTC) for EFS backups when enable\_backups is true. Defaults to daily at 05:00 UTC. | `string` | `"cron(0 5 * * ? *)"` | no |
| <a name="input_bedrock_port"></a> [bedrock\_port](#input\_bedrock\_port) | UDP port opened for Bedrock clients via the Geyser plugin. Only used on a java server with enable\_geyser = true. | `number` | `19132` | no |
| <a name="input_cpu_architecture"></a> [cpu\_architecture](#input\_cpu\_architecture) | Task CPU architecture. Fargate Spot only supports X86\_64; use ARM64 only with use\_spot = false. | `string` | `"X86_64"` | no |
| <a name="input_create_vpc"></a> [create\_vpc](#input\_create\_vpc) | Create a dedicated VPC (with public subnets, IGW, and routing). Set false to deploy into an existing VPC via vpc\_id + subnet\_ids. | `bool` | `true` | no |
| <a name="input_discord_webhook_url"></a> [discord\_webhook\_url](#input\_discord\_webhook\_url) | Discord channel webhook URL. When set, a Lambda subscribes to the SNS topic and reposts server start/stop notifications to Discord. Pass via TF\_VAR\_discord\_webhook\_url; keep it out of version control. | `string` | `""` | no |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | Fully-qualified server hostname, also created as a Route53 public hosted zone (e.g. "minecraft.hansohn.io"). The parent domain's DNS provider (Cloudflare) must delegate this subdomain to the zone's name servers — see the name\_servers output. | `string` | n/a | yes |
| <a name="input_efs_throughput_mode"></a> [efs\_throughput\_mode](#input\_efs\_throughput\_mode) | EFS throughput mode. Use "bursting" or "elastic"; avoid "provisioned" to keep costs down. | `string` | `"bursting"` | no |
| <a name="input_enable_backups"></a> [enable\_backups](#input\_enable\_backups) | Create an AWS Backup plan + vault that takes point-in-time backups of the EFS world data. EFS itself has no restore points; enabling this guards against corruption, griefing, or accidental deletion (billed per GB retained). | `bool` | `false` | no |
| <a name="input_enable_ecs_exec"></a> [enable\_ecs\_exec](#input\_enable\_ecs\_exec) | Enable ECS Exec on the task so operators can open a shell (or run rcon-cli) inside the running container via `aws ecs execute-command`. Access is gated entirely by IAM over SSM Session Manager — no inbound port is opened. Grants the task role ssmmessages permissions. | `bool` | `false` | no |
| <a name="input_enable_geyser"></a> [enable\_geyser](#input\_enable\_geyser) | On a java server, also open the Bedrock UDP port (bedrock\_port) for the Geyser plugin so Bedrock clients can join. For a native Bedrock server use server\_edition = "bedrock" instead. | `bool` | `false` | no |
| <a name="input_java_memory"></a> [java\_memory](#input\_java\_memory) | Heap size passed to itzg/minecraft-server via MEMORY. Keep it below task\_memory to leave headroom for JVM metaspace/native memory and the watchdog sidecar. | `string` | `"10G"` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | CloudWatch Logs retention for container, DNS query, and Lambda logs. | `number` | `7` | no |
| <a name="input_minecraft_env"></a> [minecraft\_env](#input\_minecraft\_env) | Extra environment variables for itzg/minecraft-server (e.g. TYPE, VERSION, MODPACK, AUTO\_CURSEFORGE settings, CF\_API\_KEY). Merged over the EULA/MEMORY defaults. | `map(string)` | `{}` | no |
| <a name="input_minecraft_image"></a> [minecraft\_image](#input\_minecraft\_image) | Minecraft server container image. Empty selects the edition default: itzg/minecraft-server for java, itzg/minecraft-bedrock-server for bedrock. | `string` | `""` | no |
| <a name="input_minecraft_port"></a> [minecraft\_port](#input\_minecraft\_port) | TCP port the Java server listens on. Ignored when server\_edition = "bedrock" (native Bedrock uses UDP 19132). | `number` | `25565` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix applied to all resources. | `string` | `"minecraft"` | no |
| <a name="input_notification_email"></a> [notification\_email](#input\_notification\_email) | If set, subscribes this email address to the SNS topic for start/stop notifications. | `string` | `""` | no |
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
| <a name="input_watchdog_image"></a> [watchdog\_image](#input\_watchdog\_image) | Watchdog sidecar image that points DNS at the task on boot and scales the service to zero when idle. | `string` | `"doctorray/minecraft-ecsfargate-watchdog:latest"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_ecs_cluster_name"></a> [ecs\_cluster\_name](#output\_ecs\_cluster\_name) | ECS cluster name. |
| <a name="output_ecs_service_name"></a> [ecs\_service\_name](#output\_ecs\_service\_name) | ECS service name. |
| <a name="output_efs_id"></a> [efs\_id](#output\_efs\_id) | EFS file system ID holding the world data. |
| <a name="output_hosted_zone_id"></a> [hosted\_zone\_id](#output\_hosted\_zone\_id) | Route53 hosted zone ID. |
| <a name="output_name_servers"></a> [name\_servers](#output\_name\_servers) | Route53 name servers for the delegated zone. Create NS records for this subdomain at your parent-domain DNS provider (Cloudflare), DNS-only / unproxied. |
| <a name="output_server_address"></a> [server\_address](#output\_server\_address) | Hostname players connect to. |
| <a name="output_sns_topic_arn"></a> [sns\_topic\_arn](#output\_sns\_topic\_arn) | SNS topic ARN for start/stop notifications. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC ID hosting the server (created or caller-supplied). |
<!-- END_TF_DOCS -->

<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
