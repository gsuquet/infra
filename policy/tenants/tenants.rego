# Tenant AppProjects: every AppProject that is not a platform one.
# A tenant deploys only from the gitops repo, into its own namespaces on its
# own cluster, with no cluster-scoped resource and no network policy of its
# own. tenants/<tenant>.yaml is the source of its namespaces: policy:check
# passes them as data.clusters.
package tenants

import data.common.manifests
import data.gitops.tenants as tenants

# Helper rules: in the body of deny, OPA would evaluate the undefined
# reference before the negation, and the rule would never fire.
data_loaded if is_object(tenants)

clusters_loaded if is_object(data.clusters)

deny contains msg if {
	not data_loaded
	msg := "data.gitops.tenants is missing: run conftest with --data policy/data"
}

deny contains msg if {
	not clusters_loaded
	msg := "data.clusters is missing: run 'mise run policy:check', which generates it from the cluster.yaml files"
}

# tenant_namespaces(path, project): the namespaces of the tenant in its
# gitops/tenants/<tenant>.yaml, when the cluster that rendered path lists it.
tenant_namespaces(path, project) := data.clusters[manifests.cluster(path)].tenants[project]

# platform_namespace(path, namespace): the namespace of a component enabled
# on the same cluster.
platform_namespace(path, namespace) if {
	some component_namespace in data.clusters[manifests.cluster(path)].components
	component_namespace == namespace
}

onboarded(path, project) if tenant_namespaces(path, project)

allowed_namespace(path, project, namespace) if {
	namespace in tenant_namespaces(path, project)
	not platform_namespace(path, namespace)
}

# allowed_cluster(destination): the cluster Argo CD runs in. A destination
# sets server, name, or both, and each one it sets must match.
allowed_cluster(destination) if {
	some key in ["server", "name"]
	destination[key]
	object.get(destination, "server", tenants.destination.server) == tenants.destination.server
	object.get(destination, "name", tenants.destination.name) == tenants.destination.name
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
	clusters_loaded
	some [path, obj] in tenant_projects
	not onboarded(path, obj.metadata.name)
	msg := sprintf("%s: the AppProject %q is not a tenant of %s: add it to the tenants of its cluster.yaml, or to the platform projects of policy/data/gitops.yaml", [path, obj.metadata.name, manifests.cluster(path)])
}

# Destinations: only the tenant's own namespaces (no wildcard, no platform
# namespace), only on the cluster Argo CD runs in.
deny contains msg if {
	some [path, obj] in tenant_projects
	onboarded(path, obj.metadata.name)
	some destination in object.get(obj, ["spec", "destinations"], [])
	namespace := object.get(destination, "namespace", "")
	not allowed_namespace(path, obj.metadata.name, namespace)
	msg := sprintf("%s: the tenant AppProject %q must not deploy to the namespace %q: allowed are the namespaces of its tenant file, %v", [path, obj.metadata.name, namespace, tenant_namespaces(path, obj.metadata.name)])
}

deny contains msg if {
	some [path, obj] in tenant_projects
	some destination in object.get(obj, ["spec", "destinations"], [])
	not allowed_cluster(destination)
	msg := sprintf("%s: the tenant AppProject %q must deploy to its own cluster only: server %q or name %q, got %v", [path, obj.metadata.name, tenants.destination.server, tenants.destination.name, destination])
}
