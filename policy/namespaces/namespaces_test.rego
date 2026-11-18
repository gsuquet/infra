package namespaces_test

import data.namespaces

namespace(name, labels) := {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": name, "labels": labels}}

file(obj) := [{"path": "gitops/clusters/kind-dev/rendered/argocd/namespace-argocd.yaml", "contents": obj}]

test_labelled_namespace_passes if {
	count(namespaces.deny) == 0 with input as file(namespace("argocd", {"network.infra.gsuquet.com/policy": "default-deny"}))
}

test_namespace_without_label_fails if {
	some msg in namespaces.deny with input as file(namespace("argocd", {}))
	contains(msg, "network.infra.gsuquet.com/policy")
}

test_namespace_without_metadata_labels_fails if {
	obj := {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "argocd"}}
	count(namespaces.deny) == 1 with input as file(obj)
}

test_namespace_with_other_value_fails if {
	count(namespaces.deny) == 1 with input as file(namespace("argocd", {"network.infra.gsuquet.com/policy": "allow-all"}))
}

test_exempt_namespace_passes if {
	count(namespaces.deny) == 0 with input as file(namespace("kube-system", {}))
}

test_other_kinds_pass if {
	obj := {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "argocd"}}
	count(namespaces.deny) == 0 with input as file(obj)
}

test_missing_data_fails if {
	some msg in namespaces.deny with input as [] with data.gitops as {}
	contains(msg, "--data policy/data")
}
