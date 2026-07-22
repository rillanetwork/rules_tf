variable "input_var" {
  description = "an input var"
  type        = string
  default     = "foobar"
}

variable "regions" {
  description = "a typed list of strings, exercising JSON tfvars"
  type        = list(string)
  default     = []
}

variable "enabled" {
  description = "a typed bool, exercising JSON tfvars"
  type        = bool
  default     = false
}

variable "replica_count" {
  description = "a typed number, exercising JSON tfvars"
  type        = number
  default     = 0
}

variable "labels" {
  description = "a typed nested map, exercising JSON tfvars"
  type        = map(string)
  default     = {}
}
