#!/bin/bash

set_variables() { 
    export RESOURCE_GROUP=mask8test-rg
    export KEYVAULT_NAME=mask8test-kv
    export LOCATION=centralus

    export MGMT_VM_NAME=masmonk8
    export MGMT_DNS_NAME=masmonk8
    export MGMT_VM_SIZE=Standard_DS4_v2
    export MGMT_VM_IMAGE=UbuntuLTS
    export MGMT_USERNAME=masimms

    export K8_NODE_SIZE=Standard_DS4_v2
    export K8_DISK_SIZE=1023
    export K8_NODE_COUNT=6
    export K8_DNS_PREFIX=mask8test-k8
    export K8_CLUSTER_NAME=mask8test-k8

    # Virtual Network

    # TODO - generate K8_VNET_SUBNET_MASTER
    export K8_VNET_NAME=funcexprk8-vnet
    export K8_VNET_CIDR=10.10.0.0/16

    export K8_VNET_SUBNET_MGMT_NAME=k8mgmt-subnet
    export K8_VNET_SUBNET_MGMT_CIDR=10.10.3.0/24    
    export K8_VNET_SUBNET_MGMT_VMIP=10.10.3.10

    export K8_VNET_SUBNET_MASTER_NAME=k8master-subnet
    export K8_VNET_SUBNET_MASTER_CIDR=10.10.1.0/24    
    export K8_VNET_SUBNET_MASTER_FIRSTIP=10.10.1.239

    export K8_VNET_SUBNET_AGENT_NAME=k8agent-subnet
    export K8_VNET_SUBNET_AGENT_CIDR=10.10.2.0/24

    # Shared Keyvault
    export KEYVAULT_NAME=funcexpk8-kv

    # Container registry
    export REGISTRY_NAME=funcexpk8reg
    export REGISTRY_LOGINSERVER=funcexpk8reg.azurecr.io

    # Shared resources
    export SHARE_NAME=scriptshare
    export STORAGE_NAME=masfunctest
}


deploy_shared() { 
    # Create the basic resource group
    az group create --name $RESOURCE_GROUP --location $LOCATION

    # Create a virtual network and related subnets
    az network vnet create --resource-group ${RESOURCE_GROUP} \
        --name ${K8_VNET_NAME} --address-prefixes ${K8_VNET_CIDR} 

    az network vnet subnet create --resource-group ${RESOURCE_GROUP} \
        --vnet-name $K8_VNET_NAME --name $K8_VNET_SUBNET_MGMT_NAME \
        --address-prefix $K8_VNET_SUBNET_MGMT_CIDR

    az network vnet subnet create --resource-group ${RESOURCE_GROUP} \
        --vnet-name $K8_VNET_NAME --name $K8_VNET_SUBNET_MASTER_NAME \
        --address-prefix $K8_VNET_SUBNET_MASTER_CIDR

    az network vnet subnet create --resource-group ${RESOURCE_GROUP} \
        --vnet-name $K8_VNET_NAME --name $K8_VNET_SUBNET_AGENT_NAME \
        --address-prefix $K8_VNET_SUBNET_AGENT_CIDR

    # Create a key vault
    az keyvault create --resource-group ${RESOURCE_GROUP} \
        --location ${LOCATION} --sku standard \
        --name ${KEYVAULT_NAME}

    # Create and store the jumpbox keys
    if [ ! -f ~/.ssh/vnettest-jumpbox ]; then
        echo "Creating jumpbox SSH keys"

        # TODO - check to see if the keys exist before regenerating
        ssh-keygen -f ~/.ssh/vnettest-jumpbox -P ""
    fi
    export SSH_KEYDATA=`cat ~/.ssh/vnettest-jumpbox.pub`

    az keyvault secret set --vault-name ${KEYVAULT_NAME} \
        --name jumpbox-ssh --file  ~/.ssh/vnettest-jumpbox
    az keyvault secret set --vault-name ${KEYVAULT_NAME} \
        --name jumpbox-ssh-pub --file  ~/.ssh/vnettest-jumpbox.pub

    # Generate a windows password for auth
    if [ ! -f ~/.ssh/vnettest-password ]; then
        mgmt_pw=$(pwgen 16 1)
        echo $mgmt_pw > ~/.ssh/vnettest-password
        chmod 600  ~/.ssh/vnettest-password
    fi
    export MGMT_PASSWORD=$(cat  ~/.ssh/vnettest-password)
    az keyvault secret set --vault-name ${KEYVAULT_NAME} \
        --name jumpbox-pw --file ~/.ssh/vnettest-password
    
    echo "Creating service principal"
    export subid=$(az account show --query id | tr -d '"')
    az ad sp create-for-rbac --role="Contributor" \
        --scopes="/subscriptions/$subid/resourceGroups/$RESOURCE_GROUP" > adrole.json
    export spid=$(cat adrole.json | jq .appId | tr -d '"')
    export sppw=$(cat adrole.json | jq .password | tr -d '"')
    echo "Service principal app id = $spid"

    # Create the container registry
    echo "Creating container registry"

    # TODO - auth the acr to the cluster below
    az acr create --resource-group $RESOURCE_GROUP \
        --name $REGISTRY_NAME --sku Basic --admin-enabled true
    registryId=$(az acr show --resource-group $RESOURCE_GROUP --name $REGISTRY_NAME \
        --query id --output tsv)    
     az role assignment create --scope $registryId \
         --role Owner --assignee $spid

}


deploy_monitoring_vm() {
    # Create the monitoring VM
    az vm create --resource-group $RESOURCE_GROUP --name $MGMT_VM_NAME \
        --location $LOCATION --image $MGMT_VM_IMAGE \
        --admin-username $MGMT_USERNAME --ssh-key-value "${SSH_KEYDATA}" \
        --authentication-type ssh \
        --size $MGMT_VM_SIZE \
        --storage-sku Premium_LRS \
        --public-ip-address-dns-name $MGMT_DNS_NAME \
        --custom-data supporting/monserver-cloud-init.txt \
        --vnet-name $K8_VNET_NAME --subnet $K8_VNET_SUBNET_MGMT_NAME \
        --private-ip-address $K8_VNET_SUBNET_MGMT_VMIP \
        --data-disk-sizes-gb 1024

    az vm open-port --resource-group $RESOURCE_GROUP --name $MGMT_VM_NAME \
        --port 5601 --priority 100
    az vm open-port --resource-group $RESOURCE_GROUP --name $MGMT_VM_NAME \
        --port 3000 --priority 101

    # # Allow access to monitoring ports
    # # TODO - lock down publish from K8 host
    # nsgName=$(az network nsg list --resource-group $RESOURCE_GROUP | \
    #     jq ".[].name|select(startswith(\"$MGMT_VM_NAME\"))" | tr -d '"')
        
    # az network nsg rule create --resource-group $RESOURCE_GROUP --nsg-name $nsgName \
    #     --name allow-monitoring-influx-rule --priority 105 \
    #     --description "Allow incoming connections to InfluxDB" \
    #     --protocol tcp --access Allow --direction Inbound \
    #     --destination-port-ranges 8086

    # az network nsg rule create --resource-group $RESOURCE_GROUP --nsg-name $nsgName \
    #     --name allow-monitoring-grafana-rule --priority 106 \
    #     --description "Allow incoming connections to Grafana" \
    #     --protocol tcp --access Allow --direction Inbound \
    #     --destination-port-ranges 3000

    # az network nsg rule create --resource-group $RESOURCE_GROUP --nsg-name $nsgName \
    #     --name allow-monitoring-elasticsearch-rule --priority 107 \
    #     --description "Allow incoming connections to ElasticSearch" \
    #     --protocol tcp --access Allow --direction Inbound \
    #     --destination-port-ranges 9200

    # az network nsg rule create --resource-group $RESOURCE_GROUP --nsg-name $nsgName \
    #     --name allow-monitoring-kibana-rule --priority 108 \
    #     --description "Allow incoming connections to Kibana" \
    #     --protocol tcp --access Allow --direction Inbound \
    #     --destination-port-ranges 5601

    # TODO - may need to add inbound port allows
}

deploy_aks_k8() { 
    echo "Creating k8 cluster"
    az aks create --resource-group ${RESOURCE_GROUP} \
        --name ${K8_CLUSTER_NAME} \
        --admin-username ${MGMT_USERNAME} 
        --location ${LOCATION} \
        --dns-name-prefix ${K8_DNS_PREFIX} \
        --agent-vm-size ${K8_NODE_SIZE} \
        --agent-count $K8_NODE_COUNT \
        --ssh-key-value "${SSH_KEYDATA}" 
}

deploy_acs_k8() { 
    echo "Creating k8 cluster"

    az acs create --orchestrator-type=kubernetes \
        --resource-group $RESOURCE_GROUP \
        --dns-prefix $K8_DNS_PREFIX \
        --name $K8_CLUSTER_NAME \
        --agent-vm-size $K8_NODE_SIZE \
        --agent-count $K8_NODE_COUNT \
        --agent-storage-profile ManagedDisks \
        --agent-osdisk-size 1023 \
        --master-count 3 \
        --master-vm-size Standard_D2_v2 \
        --master-storage-profile ManagedDisks \
        --orchestrator-version 1.8.1 \
        --service-principal $spid \
        --client-secret $sppw \
        --ssh-key-value "$SSH_KEYDATA"
        
    az acs kubernetes get-credentials \
        --resource-group=$RESOURCE_GROUP --name=$K8_CLUSTER_NAME \
        --ssh-key-file ~/.ssh/vnettest-jumpbox

    az acs kubernetes browse --resource-group $RESOURCE_GROUP \
        --name $K8_CLUSTER_NAME --ssh-key-file ~/.ssh/vnettest-jumpbox

    # Label all of the agent nodes for log collection
    LABEL='beta.kubernetes.io/fluentd-ds-ready=true'
    NODES=($(kubectl get nodes --selector=kubernetes.io/role=agent -o jsonpath='{.items[*].metadata.name}'))
    for node in "${NODES[@]}"
    do
        echo "adding label:$LABEL to node:$node"
        kubectl label nodes "$node" $LABEL 
    done

      

    # Prepare agent nodes 0..2 as disk hosting nodes (for glusterfs, etc)
    # TODO - attach disks
    # TODO - label the nodes

    # Label the remainder of the nodes as worker nodes


}

deploy_acs_engine_k8() {
    export master_subnetid=$(az network vnet subnet show --resource-group ${RESOURCE_GROUP} --vnet-name ${K8_VNET_NAME} --name $K8_VNET_SUBNET_MASTER_NAME --query id --output tsv)
    export agent_subnetid=$(az network vnet subnet show --resource-group ${RESOURCE_GROUP} --vnet-name ${K8_VNET_NAME} --name $K8_VNET_SUBNET_AGENT_NAME --query id --output tsv)

    cp kubernetes-cluster-definition.json kubernetes-deployment.json
    echo "Updating deployment settings in file kubernetes-deployment.json"
    sed -i'' "s/%K8_DNS_PREFIX%/$K8_DNS_PREFIX/" kubernetes-deployment.json
    sed -i'' "s#%K8_VNET_SUBNET_MASTER%#$master_subnetid#" kubernetes-deployment.json
    sed -i'' "s/%K8_VNET_SUBNET_MASTER_FIRSTIP%/$K8_VNET_SUBNET_MASTER_FIRSTIP/" kubernetes-deployment.json
    sed -i'' "s#%K8_VNET_CIDR%#$K8_VNET_CIDR#" kubernetes-deployment.json
    sed -i'' "s/%K8_NODE_SIZE%/$K8_NODE_SIZE/" kubernetes-deployment.json
    sed -i'' "s#%K8_VNET_SUBNET_AGENT%#$agent_subnetid#" kubernetes-deployment.json
    
    sed -i'' "s/%MGMT_USERNAME%/$MGMT_USERNAME/" kubernetes-deployment.json
    sed -i'' "s/%MGMT_PASSWORD%/$MGMT_PASSWORD/" kubernetes-deployment.json
    sed -i'' "s#%SSH_KEYDATA%#$SSH_KEYDATA#" kubernetes-deployment.json
    sed -i'' "s/%SP_CLIENTID%/$spid/" kubernetes-deployment.json
    sed -i'' "s/%SP_SECRET%/$sppw/" kubernetes-deployment.json    

    acs-engine deploy --subscription-id $subid \
        --location $LOCATION \
        --resource-group $RESOURCE_GROUP \
        --api-model kubernetes-deployment.json

    # Get the kubectl configuration
    export master_fqdn=${K8_CLUSTER_NAME}.${LOCATION}.cloudapp.azure.com
    scp -o StrictHostKeyChecking=no -i ~/.ssh/vnettest-jumpbox.pub \
        $MGMT_USERNAME@$master_fqdn:.kube/config .
    export KUBECONFIG=`pwd`/config
    cp $KUBECONFIG ~/.kube/config    
}

configure_k8() { 
    # Create the service account and role bindings - TODO - create custom clusterrole
    kubectl create serviceaccount fluentd-es
    kubectl create clusterrolebinding fluentd-es \
        --clusterrole=system:heapster-with-nanny \
        --serviceaccount=kube-system:fluentd-es

    # Deploy fluentd for moving system logs to ELK
    kubectl create -f fluentd-configmap.yaml
    kubectl create -f fluentd-service.yaml

    # Deploy heapster for logging to influxdb
    kubectl apply -f heapster-to-influx.yaml
}

configure_glusterfs() {
    ssh -o StrictHostKeyChecking=no -i ~/.ssh/vnettest-jumpbox.pub \
        $MGMT_USERNAME@$master_fqdn

    # Execute the glusterfs-client install script on each gluster agent node
    # sudo apt install glusterfs-client
    NODES=($(kubectl get nodes --selector=functions-role=worker -o jsonpath='{.items[*].metadata.name}'))
    for node in "${NODES[@]}"
    do
        echo "Installing glusterfs on $node"
        ssh -o StrictHostKeyChecking=no -i ~/.ssh/vnettest-jumpbox \
            -o ProxyCommand="ssh -o StrictHostKeyChecking=no -i ~/.ssh/vnettest-jumpbox -W %h:%p ${MGMT_USERNAME}@${master_fqdn}" \
            -l ${MGMT_USERNAME} ${node} \
            sudo apt-get install -Y glusterfs-client
    done
}

retrieve_credentials() 
{
    az keyvault secret download --vault-name ${KEYVAULT_NAME} \
        --name jumpbox-ssh --file  ~/.ssh/vnettest-jumpbox
    az keyvault secret download --vault-name ${KEYVAULT_NAME} \
        --name jumpbox-ssh-pub --file  ~/.ssh/vnettest-jumpbox.pub
    chmod 600 ~/.ssh/vnettest-jumpbox 
    chmod 600 ~/.ssh/vnettest-jumpbox.pub

    export master_fqdn=${K8_CLUSTER_NAME}.${LOCATION}.cloudapp.azure.com
    scp -o StrictHostKeyChecking=no -i ~/.ssh/vnettest-jumpbox \
        $MGMT_USERNAME@$master_fqdn:.kube/config .
    export KUBECONFIG=`pwd`/config
    cp $KUBECONFIG ~/.kube/config    
}

create_shared_resources()
{
    az storage account create --resource-group $RESOURCE_GROUP \
        --name $STORAGE_NAME --location $LOCATION
    az storage share create --account-name $STORAGE_NAME \
        --name $SHARE_NAME

    STORAGE_KEY=$(az storage account keys list \
        --resource-group $RESOURCE_GROUP \
        --account-name $STORAGE_NAME --query "[0].value" -o tsv)

    echo -n $STORAGE_NAME > "storage.txt"
    echo -n $STORAGE_KEY > "storage-key.txt"

    kubectl create secret generic script-azure-file \
        --from-file=azurestorageaccountname=./storage.txt \
        --from-file=azurestorageaccountkey=./storage-key.txt

    rm storage.txt
    rm storage-key.txt
}

main() { 
    set_variables
    deploy_shared
    deploy_monitoring_vm

    #deploy_aks_k8
    #deploy_acs_k8
    deploy_acs_engine_k8

    configure_k8
}

main
