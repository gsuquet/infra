package namespaces_test

import data.namespaces

label := {"network.infra.gsuquet.com/policy": "default-deny"}

namespace(name, labels) := {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": name, "labels": labels}}

configmap(namespace) := {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "x", "namespace": namespace}}

path(file) := sprintf("gitops/clusters/kind-dev/rendered/argocd/%s", [file])

file(obj) := [{"path": path("namespace-argocd.yaml"), "contents": obj}]

# data.clusters as policy:check generates it.
clusters := {"gitops/clusters/kind-dev": {"components": {"argocd": "argocd"}, "tenants": {}}}

test_labelled_namespace_passes if {
	count(namespaces.deny) == 0 with input as file(namespace("argocd", label)) with data.clusters as clusters
}

test_namespace_without_label_fails if {
	some msg in namespaces.deny with input as file(namespace("argocd", {})) with data.clusters as clusters
	contains(msg, "network.infra.gsuquet.com/policy")
}

test_namespace_without_metadata_labels_fails if {
	obj := {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "argocd"}}
	count(namespaces.deny) == 1 with input as file(obj) with data.clusters as clusters
}

test_namespace_with_other_value_fails if {
	obj := namespace("argocd", {"network.infra.gsuquet.com/policy": "allow-all"})
	count(namespaces.deny) == 1 with input as file(obj) with data.clusters as clusters
}

test_exempt_namespace_passes if {
	files := [
		{"path": path("namespace-argocd.yaml"), "contents": namespace("argocd", label)},
		{"path": path("namespace-kube-system.yaml"), "contents": namespace("kube-system", {})},
		{"path": path("configmap-kube-system-x.yaml"), "contents": configmap("kube-system")},
	]
	count(namespaces.deny) == 0 with input as files with data.clusters as clusters
}

test_component_namespace_not_rendered_fails if {
	some msg in namespaces.deny with input as [] with data.clusters as clusters
	contains(msg, `the namespace "argocd" (the namespace of the component "argocd") has no rendered Namespace`)
}

test_resource_namespace_not_rendered_fails if {
	files := [
		{"path": path("namespace-argocd.yaml"), "contents": namespace("argocd", label)},
		{"path": path("configmap-monitoring-x.yaml"), "contents": configmap("monitoring")},
	]
	some msg in namespaces.deny with input as files with data.clusters as clusters
	contains(msg, `the namespace "monitoring" (used by`)
}

test_namespace_rendered_on_another_cluster_fails if {
	files := [
		{"path": path("namespace-argocd.yaml"), "contents": namespace("argocd", label)},
		{"path": "gitops/clusters/gke-prod/rendered/x/namespace-monitoring.yaml", "contents": namespace("monitoring", label)},
		{"path": path("configmap-monitoring-x.yaml"), "contents": configmap("monitoring")},
	]
	count(namespaces.deny) == 1 with input as files with data.clusters as clusters
}

test_tenant_namespace_not_rendered_fails if {
	tenants := {"gitops/clusters/kind-dev": {"components": {"argocd": "argocd"}, "tenants": {"team-a": ["team-a"]}}}
	some msg in namespaces.deny with input as file(namespace("argocd", label)) with data.clusters as tenants
	contains(msg, `a namespace of the tenant "team-a"`)
}

test_other_kinds_pass if {
	files := [
		{"path": path("namespace-argocd.yaml"), "contents": namespace("argocd", label)},
		{"path": path("configmap-x.yaml"), "contents": configmap("argocd")},
	]
	count(namespaces.deny) == 0 with input as files with data.clusters as clusters
}

test_missing_data_fails if {
	some msg in namespaces.deny with input as [] with data.gitops as {} with data.clusters as clusters
	contains(msg, "--data policy/data")
}

test_missing_clusters_fails if {
	some msg in namespaces.deny with input as file(namespace("argocd", label)) with data.clusters as null
	contains(msg, "policy:check")
}
