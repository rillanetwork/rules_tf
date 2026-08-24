output "both" {
  description = "proves each call path resolved to its own copy of the closure"
  value = {
    first  = module.first.ids
    second = module.second.ids
  }
}
