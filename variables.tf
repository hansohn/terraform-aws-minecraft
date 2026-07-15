################################################################################
# Variables
################################################################################

variable "name" {
  type        = string
  default     = "minecraft"
  description = "Name prefix applied to all resources."
}

variable "domain_name" {
  type        = string
  description = "Fully-qualified server hostname, also created as a Route53 public hosted zone (e.g. \"minecraft.hansohn.io\"). The parent domain's DNS provider (Cloudflare) must delegate this subdomain to the zone's name servers — see the name_servers output."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.100.0.0/24"
  description = "CIDR block for the VPC that hosts the server."
}

variable "task_cpu" {
  type        = number
  default     = 2048
  description = "Fargate task vCPU units (2048 = 2 vCPU). Must be a valid Fargate CPU/memory pairing."
}

variable "task_memory" {
  type        = number
  default     = 16384
  description = "Fargate task memory in MiB (16384 = 16 GB)."
}

variable "java_memory" {
  type        = string
  default     = "10G"
  description = "Heap size passed to itzg/minecraft-server via MEMORY. Keep it below task_memory to leave headroom for JVM metaspace/native memory and the watchdog sidecar."
}

variable "use_spot" {
  type        = bool
  default     = true
  description = "Run the task on Fargate Spot (much cheaper; rare interruptions just restart the server). Spot is x86 only."
}

variable "cpu_architecture" {
  type        = string
  default     = "X86_64"
  description = "Task CPU architecture. Fargate Spot only supports X86_64; use ARM64 only with use_spot = false."
}

variable "server_edition" {
  type        = string
  default     = "java"
  description = "Minecraft edition to run. \"java\" listens on TCP (minecraft_port); \"bedrock\" runs a native Bedrock server on UDP 19132. Drives the game port protocol and the default container image."

  validation {
    condition     = contains(["java", "bedrock"], var.server_edition)
    error_message = "server_edition must be \"java\" or \"bedrock\"."
  }
}

variable "minecraft_image" {
  type        = string
  default     = ""
  description = "Minecraft server container image. Empty selects the edition default: itzg/minecraft-server for java, itzg/minecraft-bedrock-server for bedrock."
}

variable "watchdog_image" {
  type        = string
  default     = "doctorray/minecraft-ecsfargate-watchdog:latest"
  description = "Watchdog sidecar image that points DNS at the task on boot and scales the service to zero when idle."
}

variable "minecraft_port" {
  type        = number
  default     = 25565
  description = "TCP port the Java server listens on. Ignored when server_edition = \"bedrock\" (native Bedrock uses UDP 19132)."
}

variable "bedrock_port" {
  type        = number
  default     = 19132
  description = "UDP port opened for Bedrock clients via the Geyser plugin. Only used on a java server with enable_geyser = true."
}

variable "enable_geyser" {
  type        = bool
  default     = false
  description = "On a java server, also open the Bedrock UDP port (bedrock_port) for the Geyser plugin so Bedrock clients can join. For a native Bedrock server use server_edition = \"bedrock\" instead."
}

variable "minecraft_env" {
  type        = map(string)
  default     = {}
  description = "Extra environment variables for itzg/minecraft-server (e.g. TYPE, VERSION, MODPACK, AUTO_CURSEFORGE settings, CF_API_KEY). Merged over the EULA/MEMORY defaults."
}

variable "startup_minutes" {
  type        = number
  default     = 10
  description = "Grace period (minutes) the watchdog waits for a first connection before it may shut the server down."
}

variable "shutdown_minutes" {
  type        = number
  default     = 20
  description = "Idle time (minutes) with no players before the watchdog scales the service to zero."
}

variable "efs_throughput_mode" {
  type        = string
  default     = "bursting"
  description = "EFS throughput mode. Use \"bursting\" or \"elastic\"; avoid \"provisioned\" to keep costs down."
}

variable "discord_webhook_url" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Discord channel webhook URL. When set, a Lambda subscribes to the SNS topic and reposts server start/stop notifications to Discord. Pass via TF_VAR_discord_webhook_url; keep it out of version control."
}

variable "allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDR blocks allowed to reach the game port(s). Defaults to open (0.0.0.0/0); narrow to known player IPs to lock the server down. Note the port must stay reachable from wherever players connect for the wake-on-DNS launcher to trigger."
}

variable "enable_backups" {
  type        = bool
  default     = false
  description = "Create an AWS Backup plan + vault that takes point-in-time backups of the EFS world data. EFS itself has no restore points; enabling this guards against corruption, griefing, or accidental deletion (billed per GB retained)."
}

variable "backup_schedule" {
  type        = string
  default     = "cron(0 5 * * ? *)"
  description = "Cron schedule (UTC) for EFS backups when enable_backups is true. Defaults to daily at 05:00 UTC."
}

variable "backup_retention_days" {
  type        = number
  default     = 35
  description = "Days to retain each EFS backup recovery point when enable_backups is true."
}

variable "log_retention_days" {
  type        = number
  default     = 7
  description = "CloudWatch Logs retention for container, DNS query, and Lambda logs."
}

variable "notification_email" {
  type        = string
  default     = ""
  description = "If set, subscribes this email address to the SNS topic for start/stop notifications."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags applied to all resources."
}
