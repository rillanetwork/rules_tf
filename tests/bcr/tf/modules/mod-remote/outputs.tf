output "ids" {
  description = "proves each mirrored module was installed and evaluated"
  value = {
    label    = module.label.id
    from_git = module.from_git.id
  }
}

# The exports subdirectory publishes no outputs of its own, so referencing the
# module at all is what proves the //subdir entry resolved to a real directory
# inside the mirrored package.
output "exported" {
  description = "proves the //subdir entry resolved"
  value       = module.exported
}
