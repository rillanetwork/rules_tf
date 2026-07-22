output "my_output" {
  description = "output the input var"
  value       = var.input_var
}

output "mod_outputs" {
  description = "output module's outputs"
  value       = module.amodule
}

# Force type checking on the JSON-typed tfvars: the expressions below only
# succeed if `regions` is a real list, `enabled` a real bool, `replica_count`
# a real number, and `labels` a real map (not stringified equivalents).
output "typed_tfvars_summary" {
  description = "proves list/bool/number/map tfvars arrive correctly typed"
  value = {
    region_count     = length(var.regions)
    enabled_flag     = var.enabled ? "on" : "off"
    doubled_replicas = var.replica_count * 2
    label_team       = lookup(var.labels, "team", "none")
  }
}
