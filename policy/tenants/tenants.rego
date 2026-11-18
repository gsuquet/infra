# Tenant AppProjects: every AppProject that is not a platform one.
# A tenant deploys only from the gitops repo, into its own namespaces, with no
# cluster-scoped resource and no network policy of its own.
package tenants

import data.common.manifests
import data.gitops.tenants as tenants

# A helper rule: in the body of deny, OPA would evaluate the undefined
# reference before the negation, and the rule would never fire.
data_loaded if is_object(tenants)

deny contains msg if {
	not data_loaded
	msg := "data.gitops.tenants is missing: run conftest with --data policy/data"
}

tenant_projects contains [path, obj] if {
	some [path, obj] in manifests.resources
	obj.kind == "AppProject"
	startswith(obj.apiVersion, "argoproj.io/")
	not obj.metadata.name in tenants.platform_projects
}

# An empty or missing clusterResourceWhitelist denies every cluster-scoped
# resource in Argo CD.
deny contains msg if {
	some [path, obj] in tenant_projects
	count(object.get(obj, ["spec", "clusterResourceWhitelist"], [])) > 0
	msg := sprintf("%s: the tenant AppProject %q must not allow cluster-scoped resources: remove spec.clusterResourceWhitelist", [path, obj.metadata.name])
}

# blacklisted(entries, item): an entry matches the group and kind, or a "*".
blacklisted(entries, item) if {
	some entry in entries
	object.get(entry, "group", "") in {item.group, "*"}
	object.get(entry, "kind", "") in {item.kind, "*"}
}

deny contains msg if {
	some [path, obj] in tenant_projects
	some item in tenants.namespace_resource_blacklist
	not blacklisted(object.get(obj, ["spec", "namespaceResourceBlacklist"], []), item)
	msg := sprintf("%s: the tenant AppProject %q must list {group: %s, kind: %s} in spec.namespaceResourceBlacklist", [path, obj.metadata.name, item.group, item.kind])
}

deny contains msg if {
	some [path, obj] in tenant_projects
	some repo in object.get(obj, ["spec", "sourceRepos"], [])
	not repo in tenants.source_repos
	msg := sprintf("%s: the tenant AppProject %q must not deploy from %q: allowed are %v", [path, obj.metadata.name, repo, tenants.source_repos])
}

deny contains msg if {
	some [path, obj] in tenant_projects
	some destination in object.get(obj, ["spec", "destinations"], [])
	contains(object.get(destination, "namespace", "*"), "*")
	msg := sprintf("%s: the tenant AppProject %q must list its namespaces in spec.destinations, without a wildcard", [path, obj.metadata.name])
}
