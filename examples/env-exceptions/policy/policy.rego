package main

import rego.v1

deny_run_as_root contains msg if {
	input.kind == "Deployment"
	not input.spec.template.spec.securityContext.runAsNonRoot

	msg := sprintf("Deployment %s must not run containers as root", [input.metadata.name])
}

deny_privileged contains msg if {
	input.kind == "Deployment"
	some container in input.spec.template.spec.containers
	container.securityContext.privileged == true

	msg := sprintf("Deployment %s container %q must not be privileged", [input.metadata.name, container.name])
}
