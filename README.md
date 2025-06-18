OCP4 Deployment

./openshift-install-ocp4 create install-config

./openshift-install-ocp4 create cluster

retry the cluster deployment in case

./openshift-install-ocp4 wait-for bootstrap-complete --log-level=debug

./openshift-install-ocp4 wait-for install-complete --log-level=debug
