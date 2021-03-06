#!/bin/bash -xe

source ${P}

qs_enable_epel &> /var/log/userdata.qs_enable_epel.log

qs_retry_command 25 aws s3 cp ${QS_S3URI}scripts/redhat_ose-register-${OCP_VERSION}.sh ~/redhat_ose-register.sh
chmod 755 ~/redhat_ose-register.sh
qs_retry_command 20 ~/redhat_ose-register.sh ${RH_USER} ${RH_PASS} ${RH_POOLID}

yum repolist | grep OpenShift

qs_retry_command 10 aws autoscaling suspend-processes --auto-scaling-group-name ${OPENSHIFTMASTERASG} --scaling-processes HealthCheck --region ${AWS_REGION}

qs_retry_command 10 aws autoscaling attach-load-balancer-target-groups --auto-scaling-group-name ${OPENSHIFTMASTERASG} --target-group-arns ${OPENSHIFTMASTERINTERNALTGARN} --region ${AWS_REGION}

qs_retry_command 10 pip install boto3 &> /var/log/userdata.boto3_install.log
mkdir -p /root/ose_scaling/aws_openshift_quickstart
mkdir -p /root/ose_scaling/bin
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/__init__.py /root/ose_scaling/aws_openshift_quickstart/__init__.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/logger.py /root/ose_scaling/aws_openshift_quickstart/logger.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/scaler.py /root/ose_scaling/aws_openshift_quickstart/scaler.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/aws_openshift_quickstart/utils.py /root/ose_scaling/aws_openshift_quickstart/utils.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/bin/aws-ose-qs-scale /root/ose_scaling/bin/aws-ose-qs-scale
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/scaling/setup.py /root/ose_scaling/setup.py
qs_retry_command 10 aws s3 cp ${QS_S3URI}scripts/predefined_openshift_vars.txt /tmp/openshift_inventory_predefined_vars
pip install /root/ose_scaling

qs_retry_command 10 cfn-init -v --stack ${AWS_STACKNAME} --resource AnsibleConfigServer --configsets cfg_node_keys --region ${AWS_REGION}
qs_retry_command 10 cfn-init -v --stack ${AWS_STACKNAME} --resource AnsibleConfigServer --configsets cfg_ansible --region ${AWS_REGION}

echo openshift_master_cluster_hostname=${INTERNAL_MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
echo openshift_master_cluster_public_hostname=${MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
echo openshift_master_default_subdomain=${MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars

if [ "${ENABLE_HAWKULAR}" == "True" ] ; then
    echo openshift_metrics_hawkular_hostname=metrics.${MASTER_ELBDNSNAME} >> /tmp/openshift_inventory_userdata_vars
    echo openshift_metrics_install_metrics=true >> /tmp/openshift_inventory_userdata_vars
    echo openshift_metrics_start_cluster=true >> /tmp/openshift_inventory_userdata_vars
    echo openshift_metrics_cassandra_storage_type=dynamic >> /tmp/openshift_inventory_userdata_vars
fi

echo openshift_master_api_port=443 >> /tmp/openshift_inventory_userdata_vars
echo openshift_master_console_port=443 >> /tmp/openshift_inventory_userdata_vars
if [ "${OCP_VERSION}" == "3.9" ]; then
    echo openshift_web_console_prefix=openshift3/ose- >> /tmp/openshift_inventory_userdata_vars
    echo openshift_web_console_version=v3.9 >> /tmp/openshift_inventory_userdata_vars
fi

/bin/aws-ose-qs-scale --generate-initial-inventory --write-hosts-to-tempfiles --debug || qs_err "Generating the initial inventory failed!"
cat /tmp/openshift_ansible_inventory* >> /tmp/openshift_inventory_userdata_vars || true
sed -i 's/#pipelining = False/pipelining = True/g' /etc/ansible/ansible.cfg
sed -i 's/#log_path/log_path/g' /etc/ansible/ansible.cfg
sed -i 's/#stdout_callback.*/stdout_callback = json/g' /etc/ansible/ansible.cfg
sed -i 's/#deprecation_warnings = True/deprecation_warnings = False/g' /etc/ansible/ansible.cfg

qs_retry_command 50 ansible -m ping all

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct
yum -y update
yum -y install atomic-openshift-utils
yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder
qs_retry_command 10 yum install -y https://s3-us-west-1.amazonaws.com/amazon-ssm-us-west-1/latest/linux_amd64/amazon-ssm-agent.rpm
systemctl start amazon-ssm-agent
systemctl enable amazon-ssm-agent
CURRENT_PLAYBOOK_VERSION=https://github.com/openshift/openshift-ansible/archive/openshift-ansible-${OCP_ANSIBLE_RELEASE}.tar.gz
curl  --retry 5  -Ls ${CURRENT_PLAYBOOK_VERSION} -o openshift-ansible.tar.gz
tar -zxf openshift-ansible.tar.gz
mkdir -p /usr/share/ansible
mv openshift-ansible-* /usr/share/ansible/openshift-ansible

yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder
atomic-openshift-excluder unexclude

aws s3 cp ${QS_S3URI}scripts/scaleup_wrapper.yml  /usr/share/ansible/openshift-ansible/
aws s3 cp ${QS_S3URI}scripts/bootstrap_wrapper.yml /usr/share/ansible/openshift-ansible/
ansible-playbook /usr/share/ansible/openshift-ansible/bootstrap_wrapper.yml > /var/log/bootstrap.log
if [ "${OCP_VERSION}" == "3.7" ]; then
    ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml > /var/log/bootstrap.log
elif [ "${OCP_VERSION}" == "3.9" ]; then
    ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/prerequisites.yml > /var/log/bootstrap.log
    ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/deploy_cluster.yml >> /var/log/bootstrap.log
fi

ansible masters -a "htpasswd -b /etc/origin/master/htpasswd admin ${OCP_PASS}"
aws autoscaling resume-processes --auto-scaling-group-name ${OPENSHIFTMASTERASG} --scaling-processes HealthCheck --region ${AWS_REGION}

qs_retry_command 10 yum install -y atomic-openshift-clients
AWSSB_SETUP_HOST=$(head -n 1 /tmp/openshift_initial_masters)
mkdir -p ~/.kube/
scp $AWSSB_SETUP_HOST:~/.kube/config ~/.kube/config

if [ "${ENABLE_AWSSB}" == "Enabled" ]; then
    qs_retry_command 10 yum install -y wget
    mkdir -p ~/aws_broker_install
    cd ~/aws_broker_install
    qs_retry_command 10 wget https://s3.amazonaws.com/awsservicebroker/scripts/deploy-awsservicebroker.template.yaml
    qs_retry_command 10 wget https://s3.amazonaws.com/awsservicebroker/scripts/deploy_aws_broker.sh
    chmod +x deploy_aws_broker.sh
    export KUBECONFIG=/root/.kube/config
    qs_retry_command 10 ./deploy_aws_broker.sh
    aws s3 cp ${QS_S3URI}scripts/secrets.yaml ./secrets.yaml
    sed -i "s~<CFN_ROLE_ARN>~${AWSSB_ROLE}~g" ./secrets.yaml
    sed -i "s/<REGION>/${AWS_REGION}/" ./secrets.yaml
    sed -i "s/<VPC_ID>/${VPCID}/" ./secrets.yaml
    oc create -f ./secrets.yaml -n aws-service-broker
    oc get configmap broker-config -n aws-service-broker -o yaml > aws-sb-config.yaml
    sed -i "s/^kind: ConfigMap$/    secrets:\n&/" aws-sb-config.yaml
    for apb in $(echo 'dh-sqs-apb dh-sns-apb dh-r53-apb dh-rds-apb dh-emr-apb dh-redshift-apb dh-elasticache-apb dh-dynamodb-apb dh-s3-apb dh-athena-apb dh-kinesis-apb dh-kms-apb dh-lex-apb dh-polly-apb dh-rdsmariadb-apb dh-rdspostgresql-apb dh-rekognition-apb dh-translate-apb'); do
        sed -i "s/^kind: ConfigMap$/      - {apb_name: ${apb}, secret: aws-secret, title: aws-secret}\n&/" aws-sb-config.yaml
    done
    oc replace -f ./aws-sb-config.yaml -n aws-service-broker
    oc rollout status dc/aws-asb  -n aws-service-broker
    oc rollout latest aws-asb -n aws-service-broker
fi

rm -rf /tmp/openshift_initial_*
