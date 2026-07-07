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

This module runs a Minecraft (Java) server on **ECS Fargate that scales to
zero** — you only pay for compute while someone is actually playing. When a
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

## :sparkles: Examples

Please see the sample set of examples below for a better understanding of implementation

- [Complete](examples/complete) - Complete Example

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cpu_architecture"></a> [cpu\_architecture](#input\_cpu\_architecture) | Task CPU architecture. Fargate Spot only supports X86\_64; use ARM64 only with use\_spot = false. | `string` | `"X86_64"` | no |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | Fully-qualified server hostname, also created as a Route53 public hosted zone (e.g. "minecraft.hansohn.io"). The parent domain's DNS provider (Cloudflare) must delegate this subdomain to the zone's name servers — see the name\_servers output. | `string` | n/a | yes |
| <a name="input_efs_throughput_mode"></a> [efs\_throughput\_mode](#input\_efs\_throughput\_mode) | EFS throughput mode. Use "bursting" or "elastic"; avoid "provisioned" to keep costs down. | `string` | `"bursting"` | no |
| <a name="input_java_memory"></a> [java\_memory](#input\_java\_memory) | Heap size passed to itzg/minecraft-server via MEMORY. Keep it below task\_memory to leave headroom for JVM metaspace/native memory and the watchdog sidecar. | `string` | `"10G"` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | CloudWatch Logs retention for container, DNS query, and Lambda logs. | `number` | `7` | no |
| <a name="input_minecraft_env"></a> [minecraft\_env](#input\_minecraft\_env) | Extra environment variables for itzg/minecraft-server (e.g. TYPE, VERSION, MODPACK, AUTO\_CURSEFORGE settings, CF\_API\_KEY). Merged over the EULA/MEMORY defaults. | `map(string)` | `{}` | no |
| <a name="input_minecraft_image"></a> [minecraft\_image](#input\_minecraft\_image) | Minecraft server container image. | `string` | `"itzg/minecraft-server:latest"` | no |
| <a name="input_minecraft_port"></a> [minecraft\_port](#input\_minecraft\_port) | TCP port the Java server listens on. | `number` | `25565` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix applied to all resources. | `string` | `"minecraft"` | no |
| <a name="input_notification_email"></a> [notification\_email](#input\_notification\_email) | If set, subscribes this email address to the SNS topic for start/stop notifications. | `string` | `""` | no |
| <a name="input_shutdown_minutes"></a> [shutdown\_minutes](#input\_shutdown\_minutes) | Idle time (minutes) with no players before the watchdog scales the service to zero. | `number` | `20` | no |
| <a name="input_startup_minutes"></a> [startup\_minutes](#input\_startup\_minutes) | Grace period (minutes) the watchdog waits for a first connection before it may shut the server down. | `number` | `10` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags applied to all resources. | `map(string)` | `{}` | no |
| <a name="input_task_cpu"></a> [task\_cpu](#input\_task\_cpu) | Fargate task vCPU units (2048 = 2 vCPU). Must be a valid Fargate CPU/memory pairing. | `number` | `2048` | no |
| <a name="input_task_memory"></a> [task\_memory](#input\_task\_memory) | Fargate task memory in MiB (16384 = 16 GB). | `number` | `16384` | no |
| <a name="input_use_spot"></a> [use\_spot](#input\_use\_spot) | Run the task on Fargate Spot (much cheaper; rare interruptions just restart the server). Spot is x86 only. | `bool` | `true` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | CIDR block for the VPC that hosts the server. | `string` | `"10.100.0.0/24"` | no |
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
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC ID. |
<!-- END_TF_DOCS -->

<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
