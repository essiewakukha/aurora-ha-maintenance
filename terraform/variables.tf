variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "name" {
  type    = string
  default = "aurora-ha-lab"
}

variable "owner" {
  type    = string
  default = "portfolio"
}

variable "engine_version" {
  description = "Aurora MySQL version. Leave null to use the region's current default."
  type        = string
  default     = null
}

variable "instance_class" {
  description = "Smallest class that supports Aurora MySQL 3 keeps the lab cheap."
  type        = string
  default     = "db.t4g.medium"
}

variable "reader_count" {
  description = "0 reproduces the single-instance problem; 1+ applies the fix."
  type        = number
  default     = 0

  validation {
    condition     = var.reader_count >= 0 && var.reader_count <= 15
    error_message = "Aurora supports 0 to 15 replicas."
  }
}

variable "maintenance_window" {
  description = "Weekly window in UTC, ddd:hh24:mi-ddd:hh24:mi."
  type        = string
  default     = "sun:02:00-sun:03:00"
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach port 3306, e.g. your IP as x.x.x.x/32."
  type        = string
}

variable "publicly_accessible" {
  description = "True only so the probe can run from a laptop. Use false in real environments."
  type        = bool
  default     = true
}