# protection = "strict" guard.
#
# prevent_destroy can't be set from a variable, so this marker exists only in strict mode and carries it
# itself. Terraform fails the plan, before anything changes, if it would destroy it:
#   - it is replaced whenever the instance or its KMS key is replaced or destroyed (their IDs are unknown
#     in that plan).
#   - it is destroyed if protection is lowered, the module call is removed, or on terraform destroy.
#
# Break glass (deliberate decommissioning only): terraform state rm the guard, in a reviewed change.

resource "terraform_data" "guard" {
  count = var.protection == "strict" ? 1 : 0

  triggers_replace = [
    aws_db_instance.this.resource_id,
    aws_kms_key.this.arn,
  ]

  lifecycle {
    prevent_destroy = true
  }
}
