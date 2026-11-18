package common.manifests_test

import data.common.manifests

test_component_from_rendered_path if {
	manifests.component("gitops/clusters/kind-dev/rendered/cilium/configmap-x.yaml") == "cilium"
}

test_component_undefined_outside_rendered if {
	not manifests.component("gitops/components/cilium/sources/values.yaml")
}

test_resources_of_a_multi_document_file if {
	files := [{"path": "a.yaml", "contents": [{"kind": "ConfigMap"}, {"kind": "Secret"}, null]}]
	count(manifests.resources) == 2 with input as files
}
