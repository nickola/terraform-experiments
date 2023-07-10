# Don't print any recipes before executing them
.SILENT:

# Default target
all: plan

plan:
	terraform plan

apply:
	terraform apply

output:
	terraform output

destroy:
	terraform destroy

lint:
	terraform fmt -recursive -diff -write=false
