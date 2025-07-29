#!/usr/bin/env bash

PROJECT_NAME="benchmark"
ENVIRONMENT="prod"
LOCATION="eastus"
RESOURCE_GROUP="rg-${ENVIRONMENT}-${PROJECT_NAME}"
PROXIMITY_PLACEMENT_GROUP="ppg-${LOCATION}-${ENVIRONMENT}-${PROJECT_NAME}"
SIZE_SMALL="Standard_B4ls_v2"
SIZE_MEDIUM="Standard_B4s_v2"
PRIORITY="Regular" # Regular, Spot"
ALLOW_SSH_CIDR="$(host -4 myip.opendns.com resolver1.opendns.com | grep "has address" | awk '{print $4}')/32"

if [ "${SSH_PUBLIC_KEY}" = "" ]; then
    echo "SSH_PUBLIC_KEY is not set."
    echo "Add your public SSH key in the variable SSH_PUBLIC_KEY."
    echo ""
    echo "  export SSH_PUBLIC_KEY=\$(cat ~/.ssh/id_rsa.pub)"
    exit 1
fi

resourceGroupConfig() {
  az group create \
    --name "${1}" \
    --location "${2}"

  az ppg create \
    -n "${3}" \
    -g "${1}" \
    -l "${2}" \
    -t standard
}

networking() {
  az network public-ip create \
    --resource-group "${1}" \
    --name "net-${2}-${3}-mon-publicip" \
    --allocation-method Static \
    --sku Standard

  # Create a vnet for the lab
  # Add initially the db <-> core subnet
  az network vnet create \
    --resource-group "${1}" \
    --location "${2}" \
    --name "vnet-${2}-${3}-lab" \
    --address-prefixes 192.0.2.0/24 \
    --subnet-name subnet-db \
    --subnet-prefixes 192.0.2.0/26

  # Add the kafka subnet
  az network vnet subnet create \
    --resource-group "${1}" \
    --vnet-name "vnet-${2}-${3}-lab" \
    --name subnet-kafka \
    --address-prefixes 192.0.2.64/26

  # Add the SNMP simulation subnet
  az network vnet subnet create \
    --resource-group "${1}" \
    --vnet-name "vnet-${2}-${3}-lab" \
    --name subnet-sim \
    --address-prefixes 192.0.2.128/26

  # Add the SNMP simulation subnet
  az network vnet subnet create \
    --resource-group "${1}" \
    --vnet-name "vnet-${2}-${3}-lab" \
    --name subnet-mgmt \
    --address-prefixes 192.0.2.192/26
}

nics() {
    ## NICs for DB
    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-database-vnet-db" \
      --private-ip-address 192.0.2.4 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-db

    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-database-vnet-mgmt" \
      --private-ip-address 192.0.2.196 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-mgmt

    ## NICs for Core
    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-core-vnet-db" \
      --private-ip-address 192.0.2.5 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-db

    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-core-vnet-kafka" \
      --private-ip-address 192.0.2.69 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-kafka

    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-core-vnet-mgmt" \
      --private-ip-address 192.0.2.197 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-mgmt

    ## NICs for Kafka
    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-kafka-vnet-kafka" \
      --private-ip-address 192.0.2.68 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-kafka

    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-kafka-vnet-mgmt" \
      --private-ip-address 192.0.2.198 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-mgmt

    ## NICs for Minion
    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-minion-vnet-kafka" \
      --private-ip-address 192.0.2.70 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-kafka

    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-minion-vnet-sim" \
      --private-ip-address 192.0.2.133 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-sim

    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-minion-vnet-mgmt" \
      --private-ip-address 192.0.2.199 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-mgmt

    ## NICs for SNMP Simulator
    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-snmpsim-vnet-sim" \
      --private-ip-address 192.0.2.134 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-sim

    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-snmpsim-vnet-mgmt" \
      --private-ip-address 192.0.2.201 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-mgmt

    ## NICs for Monitoring
    az network nic create \
      --resource-group "${1}" \
      --name "nic-${2}-${3}-mon-vnet-mgmt" \
      --private-ip-address 192.0.2.200 \
      --vnet-name "vnet-${2}-${3}-lab" \
      --subnet subnet-mgmt

    # Monitoring: Assign public IP to monitoring node as an entry
    az network nic ip-config update \
      --resource-group "${1}" \
      --nic-name "nic-${2}-${3}-mon-vnet-mgmt" \
      --name ipconfig1 \
      --public-ip-address "net-${2}-${3}-mon-publicip"
}

compute() {
  az vm create \
    --resource-group "${1}" \
    --name database \
    --location "${2}" \
    --nics "nic-${2}-${3}-database-vnet-mgmt" "nic-${2}-${3}-database-vnet-db" \
    --image Canonical:ubuntu-24_04-lts:server:latest \
    --admin-username azureuser \
    --size "${SIZE_SMALL}" \
    --priority "${6}" \
    --ppg "${4}" \
    --ssh-key-value "${5}"

  az vm create \
    --resource-group "${1}" \
    --name core \
    --location "${2}" \
    --nics "nic-${2}-${3}-core-vnet-mgmt" "nic-${2}-${3}-core-vnet-db" "nic-${2}-${3}-core-vnet-kafka"\
    --image Canonical:ubuntu-24_04-lts:server:latest \
    --admin-username azureuser \
    --size "${SIZE_MEDIUM}" \
    --priority "${6}" \
    --ppg "${4}" \
    --ssh-key-value "${5}"

  az vm create \
    --resource-group "${1}" \
    --name kafka \
    --location "${2}" \
    --nics "nic-${2}-${3}-kafka-vnet-mgmt" "nic-${2}-${3}-kafka-vnet-kafka"\
    --image Canonical:ubuntu-24_04-lts:server:latest \
    --admin-username azureuser \
    --size "${SIZE_SMALL}" \
    --priority "${6}" \
    --ppg "${4}" \
    --ssh-key-value "${5}"

  az vm create \
    --resource-group "${1}" \
    --name minion \
    --location "${2}" \
    --nics "nic-${2}-${3}-minion-vnet-mgmt" "nic-${2}-${3}-minion-vnet-kafka" "nic-${2}-${3}-minion-vnet-sim" \
    --image Canonical:ubuntu-24_04-lts:server:latest \
    --admin-username azureuser \
    --size "${SIZE_SMALL}" \
    --priority "${6}" \
    --ppg "${4}" \
    --ssh-key-value "${5}"

  az vm create \
    --resource-group "${1}" \
    --name snmpsim \
    --location "${2}" \
    --nics "nic-${2}-${3}-snmpsim-vnet-mgmt" "nic-${2}-${3}-snmpsim-vnet-sim" \
    --image Canonical:ubuntu-24_04-lts:server:latest \
    --admin-username azureuser \
    --size "${SIZE_SMALL}" \
    --priority "${6}" \
    --ppg "${4}" \
    --ssh-key-value "${5}"

  az vm create \
    --resource-group "${1}" \
    --name mon \
    --location "${2}" \
    --nics "nic-${2}-${3}-mon-vnet-mgmt" \
    --image Canonical:ubuntu-24_04-lts:server:latest \
    --admin-username azureuser \
    --size "${SIZE_SMALL}" \
    --priority "${6}" \
    --ppg "${4}" \
    --ssh-key-value "${5}"
}

nsg() {
  # Monitoring
  az network nsg create \
    --resource-group "${1}" \
    --location "${2}" \
    --name "nsg-nic-${2}-${3}-mon-vnet-mgmt"

  az network nsg rule create \
    --resource-group "${1}" \
    --nsg-name "nsg-nic-${2}-${3}-mon-vnet-mgmt" \
    --name allow-ssh \
    --priority 100 \
    --destination-port-ranges 22 \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --source-address-prefixes ${4} \
    --destination-address-prefixes '*'

  az network nic update \
    --resource-group "${1}" \
    --name "nic-${2}-${3}-mon-vnet-mgmt" \
    --network-security-group "nsg-nic-${2}-${3}-mon-vnet-mgmt"
}

routing () {
  az network route-table create \
     --resource-group "${1}" \
     --location "${2}" \
     --name route-netsim

   az network route-table route create \
     --resource-group "${1}" \
     --route-table-name route-netsim \
     --name route-netsim \
     --address-prefix 10.42.0.0/16 \
     --next-hop-type VirtualAppliance \
     --next-hop-ip-address 192.0.2.134

  az network vnet subnet update \
     --resource-group "${1}" \
     --vnet-name vnet-${2}-${3}-lab \
     --route-table route-netsim \
     --name subnet-sim
}

dns() {
  az network private-dns zone create \
    --resource-group "${1}" \
    --name lab.local

  az network private-dns link vnet create \
    --resource-group "${1}" \
    -n MyVnetLink \
    --zone-name lab.local \
    --virtual-network vnet-${2}-${3}-lab \
    --registration-enabled true
}

resourceGroupConfig "${RESOURCE_GROUP}" "${LOCATION}" "${PROXIMITY_PLACEMENT_GROUP}"
networking "${RESOURCE_GROUP}" "${LOCATION}" "${ENVIRONMENT}"
nics "${RESOURCE_GROUP}" "${LOCATION}" "${ENVIRONMENT}"
compute "${RESOURCE_GROUP}" "${LOCATION}" "${ENVIRONMENT}" "${PROXIMITY_PLACEMENT_GROUP}" "${SSH_PUBLIC_KEY}" "${PRIORITY}" # "${EVICTION_POLICY}"
nsg "${RESOURCE_GROUP}" "${LOCATION}" "${ENVIRONMENT}" "${ALLOW_SSH_CIDR}"
routing "${RESOURCE_GROUP}" "${LOCATION}" "${ENVIRONMENT}"
dns "${RESOURCE_GROUP}" "${LOCATION}" "${ENVIRONMENT}"
