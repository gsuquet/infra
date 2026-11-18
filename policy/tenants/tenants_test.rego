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

good_spec := {
	"sourceRepos": ["https://github.com/gsuquet/gitops.git"],
	"destinations": [{"server": "https://kubernetes.default.svc", "namespace": "team-a"}],
	"namespaceResourceBlacklist": blacklist,
}

file(obj) := [{"path": "gitops/clusters/kind-dev/rendered/tenants/appproject-team-a.yaml", "contents": obj}]

test_compliant_tenant_project_passes if {
	count(tenants.deny) == 0 with input as file(project("team-a", good_spec))
}

test_empty_cluster_whitelist_passes if {
	spec := object.union(good_spec, {"clusterResourceWhitelist": []})
	count(tenants.deny) == 0 with input as file(project("team-a", spec))
}

test_cluster_scoped_resources_fail if {
	spec := object.union(good_spec, {"clusterResourceWhitelist": [{"group": "*", "kind": "*"}]})
	some msg in tenants.deny with input as file(project("team-a", spec))
	contains(msg, "cluster-scoped")
}

test_missing_blacklist_fails_twice if {
	spec := object.remove(good_spec, ["namespaceResourceBlacklist"])
	count(tenants.deny) == 2 with input as file(project("team-a", spec))
}

test_missing_cilium_policy_fails if {
	spec := object.union(good_spec, {"namespaceResourceBlacklist": [blacklist[0]]})
	some msg in tenants.deny with input as file(project("team-a", spec))
	contains(msg, "CiliumNetworkPolicy")
}

test_wildcard_kind_in_group_passes if {
	spec := object.union(good_spec, {"namespaceResourceBlacklist": [
		{"group": "networking.k8s.io", "kind": "*"},
		{"group": "cilium.io", "kind": "*"},
	]})
	count(tenants.deny) == 0 with input as file(project("team-a", spec))
}

test_other_source_repo_fails if {
	spec := object.union(good_spec, {"sourceRepos": ["*"]})
	some msg in tenants.deny with input as file(project("team-a", spec))
	contains(msg, "must not deploy from")
}

test_wildcard_destination_fails if {
	spec := object.union(good_spec, {"destinations": [{"server": "https://kubernetes.default.svc", "namespace": "*"}]})
	count(tenants.deny) == 1 with input as file(project("team-a", spec))
}

test_destination_without_namespace_fails if {
	spec := object.union(good_spec, {"destinations": [{"server": "https://kubernetes.default.svc"}]})
	count(tenants.deny) == 1 with input as file(project("team-a", spec))
}

test_platform_project_is_not_a_tenant if {
	spec := {"sourceRepos": ["*"], "clusterResourceWhitelist": [{"group": "*", "kind": "*"}]}
	count(tenants.deny) == 0 with input as file(project("platform", spec))
}

test_missing_data_fails if {
	some msg in tenants.deny with input as [] with data.gitops as {}
	contains(msg, "--data policy/data")
}
