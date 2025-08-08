# 👩‍🔬 Benchmark Lab

Running OpenNMS components in various environments and workloads, makes it complicated to size and scale.
Especially when you want to size it for extremely large deployments.
There are various challenges that make this a complicated task:

External service dependencies that OpenNMS relies on and where we don't have control about it:

* Network latency between OpenNMS internal components and the monitored devices
* Agent or network service latency for the services you want to monitor
* Availability of services you want to test or agents you gather insights from your systems

## 🎯 Goals

This repository is an approach to build a lab environment as a tool to build reproducible environments for benchmarking or testing purposes.
There is a [Wiki](https://github.com/opennms-forge/opennms-benchmark/wiki) with a collection of experiments and results.

## 🧟 Non-Goals

* This repository is not intended to deploy or build production environments

## 🕹️ Usage

### Clone the repository with submodules

```
git clone https://github.com/opennms-forge/opennms-benchmark.git
cd opennms-benchmark
git submodule init
git submodule update
```

### Lab deployment in Azure

Requirements:
* az cli tool
* Azure login with permissions to use a subscription

Login to Azure with your account:

```bash
az login
```

Deploy the lab

```bash
cd azcli
./benchmark-lab.sh
```
> [!NOTE]
> The network security policy will allow only SSH access to the monitoring VM from your public IP address.

> [!TIP]
> To get access to every node without dealing with Bastion hosts or anything like that, the easiest way is to use something like [tailscale](https://tailscale.com) on the monitoring VM.
> It allows you very easily to route the whole 192.0.2.0/24 through the monitoring VM and makes it transparently available to your machine.

Here is how you can do it:

Step 1: Enable IPv4 forwarding on the monitoring VM

```
ssh azureuser@<public-ip>
sudo sysctl -w net.ipv4.ip_forward=1
```

Step 2: Install Tailscale from your account

Step 3: Advertise the 192.0.2.0/24 network

```bash
sudo tailscale up --accept-routes --advertise-routes=192.0.2.192/26
```

Step 4: Approve the advertised route in the Tailscale web UI

![tailscale-approve.png](assets/tailscale-approve.png)

Step 5: Verify connectivity

```bash
ping -c 1 192.0.2.196
ping -c 1 192.0.2.197
ping -c 1 192.0.2.198
ping -c 1 192.0.2.199
ping -c 1 192.0.2.200
ping -c 1 192.0.2.201
```

### Tools for Measurements

To monitor the components we are using Prometheus, the Node Exporter, Kafka Web UI and Grafana.
You can deploy the components with Ansible using

```bash
cd bootstrap
ansible-playbook -i inventory site.yml
```

### Deploy the OpenNMS Stack

OpenNMS Core, Minion and Kafka will be installed using our existing [Ansible OpenNMS](https://github.com/opennms-forge/ansible-opennms) roles.

> [!NOTE]
> The Ansible playbook for OpenNMS is linked as submodule in this repository so you don't have to deal with a dedicated repository.

Deploy a generic OpenNMS application stack

```bash
cd ansible-opennms
ansible-playbook --user azureuser --become -i ../ansible-inventory.yml opennms-playbook.yml --extra-vars="@../opennms-lab-vars.yml"
```
> [!IMPORTANT]
> The Prometheus JMX exporter requires right now to restart Core manually, see [issue#57](https://github.com/opennms-forge/ansible-opennms/issues/57).

### Setup SNMP Simulation

Add a local any IP route on the SNMP simulation VM to respond to any address in the 10.42/16 network
```bash
ssh azureuser@192.0.2.201 "sudo ip route add local 10.42.0.0/16 dev lo"
```

Add a route on the Minion to reach any address in 10.42.0.0 via the SNMP simulation VM
```bash
ssh azureuser@192.0.2.199 "sudo ip r a 10.42.0.0/16 via 192.0.2.134"
```

> [!IMPORTANT]
> The routing entries are not static, you have to set them again when your reboot the virtual machines
 
### Applications

You have now access to the following applications and you can prepare and run experiments.

* Grafana with login admin/admin: http://192.0.2.200:3000
* OpenNMS Web UI login admin/admin: http://192.0.2.197:8980
* Jaeger no login required: http://192.0.2.200:16686
* Kafka UI no login required: http://192.0.2.198:8080
