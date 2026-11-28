package gateway_api_test

import data.gateway_api

crd(group) := {
	"apiVersion": "apiextensions.k8s.io/v1",
	"kind": "CustomResourceDefinition",
	"metadata": {"name": sprintf("gateways.%s", [group])},
	"spec": {"group": group},
}

file(component, obj) := [{
	"path": sprintf("gitops/clusters/kind-dev/rendered/%s/customresourcedefinition-x.yaml", [component]),
	"contents": obj,
}]

test_gateway_api_crds_component_passes if {
	count(gateway_api.deny) == 0 with input as file("gateway-api", crd("gateway.networking.k8s.io"))
}

test_experimental_channel_in_owner_passes if {
	count(gateway_api.deny) == 0 with input as file("gateway-api", crd("gateway.networking.x-k8s.io"))
}

test_gateway_api_crd_from_implementation_fails if {
	some msg in gateway_api.deny with input as file("cilium", crd("gateway.networking.k8s.io"))
	contains(msg, "gateway-api")
}

test_experimental_crd_from_implementation_fails if {
	count(gateway_api.deny) == 1 with input as file("envoy-gateway", crd("gateway.networking.x-k8s.io"))
}

test_gateway_api_crd_outside_rendered_fails if {
	files := [{"path": "testdata/crd.yaml", "contents": crd("gateway.networking.k8s.io")}]
	count(gateway_api.deny) == 1 with input as files
}

test_other_crds_pass_anywhere if {
	count(gateway_api.deny) == 0 with input as file("cilium", crd("cilium.io"))
}
