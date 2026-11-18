package tenants_test

import data.tenants

blacklist := [
	{"group": "networking.k8s.io", "kind": "NetworkPolicy"},
	{"group": "cilium.io", "kind": "CiliumNetworkPolicy"},
]

project(name, spec) := {
	"apiVersion": "argoproj.io/v1alpha1",
	"kind": "AppProject",
	"metadata": {"name": name, "namespace": "argocd"},
	"spec": spec,
}

destination(namespace) := {"server": "https://kubernetes.default.svc", "namespace": namespace}

good_spec := {
	"sourceRepos": ["https://github.com/gsuquet/gitops.git"],
	"destinations": [destination("team-a"), destination("team-a-dev")],
	"namespaceResourceBlacklist": blacklist,
}

with_destinations(destinations) := object.union(good_spec, {"destinations": destinations})

file(obj) := [{"path": "gitops/clusters/kind-dev/rendered/tenants/appproject-team-a.yaml", "contents": obj}]

# data.clusters as policy:check generates it.
clusters := {"gitops/clusters/kind-dev": {
	"components": {"argocd": "argocd", "tenants": "argocd"},
	"tenants": {"team-a": ["team-a", "team-a-dev"]},
}}

denials(spec) := denied if {
	denied := tenants.deny with input as file(project("team-a", spec)) with data.clusters as clusters
}

test_compliant_tenant_project_passes if {
	count(denials(good_spec)) == 0
}

test_empty_cluster_whitelist_passes if {
	count(denials(object.union(good_spec, {"clusterResourceWhitelist": []}))) == 0
}

test_cluster_scoped_resources_fail if {
	some msg in denials(object.union(good_spec, {"clusterResourceWhitelist": [{"group": "*", "kind": "*"}]}))
	contains(msg, "cluster-scoped")
}

test_missing_blacklist_fails_twice if {
	count(denials(object.remove(good_spec, ["namespaceResourceBlacklist"]))) == 2
}

test_missing_cilium_policy_fails if {
	some msg in denials(object.union(good_spec, {"namespaceResourceBlacklist": [blacklist[0]]}))
	contains(msg, "CiliumNetworkPolicy")
}

test_wildcard_kind_in_group_passes if {
	spec := object.union(good_spec, {"namespaceResourceBlacklist": [
		{"group": "networking.k8s.io", "kind": "*"},
		{"group": "cilium.io", "kind": "*"},
	]})
	count(denials(spec)) == 0
}

test_other_source_repo_fails if {
	some msg in denials(object.union(good_spec, {"sourceRepos": ["*"]}))
	contains(msg, "must not deploy from")
}

test_wildcard_destination_fails if {
	count(denials(with_destinations([destination("*")]))) == 1
}

test_prefixed_wildcard_destination_fails if {
	count(denials(with_destinations([destination("team-a-*")]))) == 1
}

test_destination_without_namespace_fails if {
	count(denials(with_destinations([{"server": "https://kubernetes.default.svc"}]))) == 1
}

test_platform_namespace_destination_fails if {
	some msg in denials(with_destinations([destination("argocd")]))
	contains(msg, `must not deploy to the namespace "argocd"`)
}

test_kube_system_destination_fails if {
	count(denials(with_destinations([destination("kube-system")]))) == 1
}

test_other_tenant_namespace_fails if {
	count(denials(with_destinations([destination("team-b")]))) == 1
}

test_component_namespace_in_tenant_file_fails if {
	listed := {"gitops/clusters/kind-dev": {"components": {"argocd": "argocd"}, "tenants": {"team-a": ["team-a", "argocd"]}}}
	spec := with_destinations([destination("argocd")])
	count(tenants.deny) == 1 with input as file(project("team-a", spec)) with data.clusters as listed
}

test_foreign_server_fails if {
	some msg in denials(with_destinations([{"server": "https://10.0.0.1:6443", "namespace": "team-a"}]))
	contains(msg, "own cluster only")
}

test_in_cluster_name_passes if {
	count(denials(with_destinations([{"name": "in-cluster", "namespace": "team-a"}]))) == 0
}

test_foreign_name_fails if {
	count(denials(with_destinations([{"name": "gke-prod", "namespace": "team-a"}]))) == 1
}

test_destination_without_cluster_fails if {
	count(denials(with_destinations([{"namespace": "team-a"}]))) == 1
}

test_destination_with_server_and_other_name_fails if {
	count(denials(with_destinations([{"server": "https://kubernetes.default.svc", "name": "gke-prod", "namespace": "team-a"}]))) == 1
}

test_project_not_onboarded_fails if {
	some msg in tenants.deny with input as file(project("team-b", good_spec)) with data.clusters as clusters
	contains(msg, "is not a tenant of gitops/clusters/kind-dev")
}

test_platform_project_is_not_a_tenant if {
	spec := {"sourceRepos": ["*"], "clusterResourceWhitelist": [{"group": "*", "kind": "*"}]}
	count(tenants.deny) == 0 with input as file(project("platform", spec)) with data.clusters as clusters
}

test_missing_data_fails if {
	some msg in tenants.deny with input as [] with data.gitops as {} with data.clusters as clusters
	contains(msg, "--data policy/data")
}

test_missing_clusters_fails if {
	some msg in tenants.deny with input as [] with data.clusters as null
	contains(msg, "policy:check")
}
