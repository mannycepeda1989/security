data "google_project" "project" {}

locals {
  # for explanation of this key structure see warning here https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_iam#argument-reference
  # flatten([]) is to work around terraform v0.12.x bug https://github.com/hashicorp/terraform/issues/22404
  conditional_roles_mapping = merge(flatten([[
    for v in var.conditional_role_bindings : { format("%s-%s", v.role, base64sha256(join("", values(v.condition)))) = { role = v.role, condition = v.condition } }
  ]])...)
  conditional_roles_members = {
    for v in var.conditional_role_bindings : format("%s-%s", v.role, base64sha256(join("", values(v.condition)))) =>
    format("serviceAccount:%s@%s.iam.gserviceaccount.com", v.principle, lookup(v, "project", var.project))...
  }
  conditional_role_service_accounts = { for v in var.conditional_role_bindings : v.principle => v.condition.description if lookup(v, "project", "") == var.project }
}

locals {
  service_account_mapping = { for k, v in var.service_account_mapping : k => v if v.enabled }

  service_account_roles = distinct(flatten([for k, v in local.service_account_mapping : v["roles"]]))

  service_account_merged_maps = {
    for key in local.service_account_roles :
    key => distinct(flatten([for k, v in local.service_account_mapping : [for i in v["roles"] : k if i == key]]))
  }

  iam_group_roles = distinct(flatten([for k, v in var.role_group_mapping : v["roles"]]))

  role_group_merged_maps = {
    for key in local.iam_group_roles :
    key => distinct(flatten([for k, v in var.role_group_mapping : [for i in v["roles"] : k if i == key]]))
  }

  cross_project_roles = distinct(flatten([for k, v in var.cross_project_access_mapping : v["roles"]]))

  cross_project_merged_maps = {
    for key in local.cross_project_roles :
    key => distinct(flatten([for k, v in var.cross_project_access_mapping : [for i in v["roles"] : k if i == key]]))
  }

  service_accounts = merge(var.independent_service_accounts, local.service_account_mapping, local.conditional_role_service_accounts, var.workload_identity)
}

locals {
  roles = distinct(concat(flatten(keys(local.service_account_merged_maps)), flatten(keys(local.role_group_merged_maps)), flatten(keys(local.cross_project_merged_maps))))
}

locals {
  role_google_managed_service_account_mapping = tomap({
    "roles/editor" = tolist(["${data.google_project.project.number}@cloudservices.gserviceaccount.com"])
    }
  )
}

resource "google_service_account" "service_accounts" {
  for_each   = { for key, value in local.service_accounts : key => value }
  account_id = each.key
}

# import {
#   for_each = toset([ for key, value in local.service_account_mapping : key ])
#   to = google_service_account.service_accounts[each.key]
#   id = "projects/${var.project}/serviceAccounts/${each.key}@${var.project}.iam.gserviceaccount.com"
# }

resource "google_project_iam_custom_role" "wf_bucket_reader_custom_role" {
  role_id     = "storage.bucketViewer"
  title       = "Bucket viewer"
  description = "Combined role to access GCS bucket from CLoud Function"
  permissions = ["storage.buckets.get", "storage.objects.get", "storage.objects.list"]
  depends_on  = [google_service_account.service_accounts]
}

resource "google_project_iam_custom_role" "wf_datafabric_archivemanager_custom_role" {
  role_id     = "storage.dataFabricRole"
  title       = "DataFabric ArchiveManager Role"
  description = "WTC-18295: Role with specific permissions for archivemanager and data-fabric"
  permissions = ["storage.buckets.get", "storage.objects.get", "storage.objects.list", "storage.objects.create", "storage.objects.delete", "storage.objects.getIamPolicy"]
  depends_on  = [google_service_account.service_accounts]
}

resource "google_project_iam_custom_role" "wf_vault_gcp_auth_custom_role" {
  role_id     = "iam.vaultAuthRole"
  title       = "Vault GCP Auth Role"
  description = "Vault role with specific permissions for utilizing the GCP auth plugin"
  permissions = ["iam.serviceAccounts.get", "iam.serviceAccountKeys.get", "compute.instances.get", "compute.instanceGroups.list"]
  depends_on  = [google_service_account.service_accounts]
}

resource "google_project_iam_binding" "role_binding" {
  for_each = toset(local.roles)
  project  = var.project
  role     = each.value

  members = concat(
    lookup(local.service_account_merged_maps, each.value, null) != null ? formatlist("serviceAccount:%s@%s.iam.gserviceaccount.com", lookup(local.service_account_merged_maps, each.value), var.project) : [],
    lookup(local.cross_project_merged_maps, each.value, null) != null ? formatlist("serviceAccount:%s", lookup(local.cross_project_merged_maps, each.value)) : [],
    lookup(local.role_google_managed_service_account_mapping, each.value, null) != null ? formatlist("serviceAccount:%s", lookup(local.role_google_managed_service_account_mapping, each.value)) : [],
    lookup(local.role_group_merged_maps, each.value, null) != null ? formatlist("group:%s@${var.iam_groups_domain}", lookup(local.role_group_merged_maps, each.value)) : [],
    lookup(var.cross_project_user_access_mapping, each.value, null) != null ? formatlist("user:%s", lookup(var.cross_project_user_access_mapping, each.value)) : []
  )

  depends_on = [google_service_account.service_accounts, google_project_iam_custom_role.wf_bucket_reader_custom_role]
}

resource "google_service_account_iam_member" "impersonate_self_with_token" {
  for_each           = { for k, v in google_service_account.service_accounts : k => v if contains(var.service_account_token_creators, v.account_id) }
  service_account_id = each.value.id
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${each.value.email}"
}

resource "google_project_iam_member" "pubsub_service_agent" {
  member  = format("serviceAccount:service-%s@gcp-sa-pubsub.iam.gserviceaccount.com", var.project_number)
  role    = "roles/iam.serviceAccountTokenCreator"
  project = var.project
}

#
# WTC-27925: supporting service-account level user-group impersonation (instead of project-level)
#
locals {
  service_account_users_map = flatten([
    for v in google_service_account.service_accounts : [
      for g in lookup(var.service_account_user_group_mapping, v.account_id, []) : { service_account = v, group_id = g }
    ]
  ])
  service_account_users = {
    for v in local.service_account_users_map : format("%s:%s", v.service_account.account_id, v.group_id) => v
  }
}

resource "google_service_account_iam_member" "impersonate_self_with_group" {
  for_each           = local.service_account_users
  service_account_id = each.value.service_account.id
  role               = "roles/iam.serviceAccountUser"
  member             = format("group:%s@${var.iam_groups_domain}", each.value.group_id)

}

resource "google_project_iam_member" "compute_engine_agent" {
  member  = format("serviceAccount:%s-compute@developer.gserviceaccount.com", var.project_number)
  role    = "roles/compute.serviceAgent"
  project = var.project
}

resource "google_project_iam_binding" "conditional_role_binding" {
  for_each = local.conditional_roles_mapping
  project  = var.project
  role     = each.value.role
  members  = lookup(local.conditional_roles_members, each.key, [])

  depends_on = [google_service_account.service_accounts]
  condition {
    title       = each.value.condition.title
    description = each.value.condition.description
    expression  = each.value.condition.expression
  }
}

resource "google_project_service_identity" "sm_sa" {
  provider = google-beta
  project = var.project
  service = "secretmanager.googleapis.com"
}

resource "google_project_service_identity" "shared_sm_sa" {
  provider = google-beta
  project = var.sm_project
  service = "secretmanager.googleapis.com"
}
