require "open3"
require "ipaddr"
require "json"

def integer_env(name, fallback)
  value = ENV.fetch(name, fallback).to_s
  Integer(value, 10)
rescue ArgumentError
  abort "#{name} must be an integer, got #{value.inspect}"
end

IMAGE_NAME = ENV.fetch("IMAGE_NAME", "ubuntu/focal64")
IMAGE_VERSION = ENV.fetch("IMAGE_VERSION", "20240821.0.1")
CLUSTER_NETWORK_PREFIX = ENV.fetch("BASE_IP", "10.50.0")

EDGE_NETWORK_CIDR = "192.168.56.0/24"
EDGE_NETWORK = IPAddr.new(EDGE_NETWORK_CIDR)
EDGE_GATEWAY = IPAddr.new("192.168.56.1")
METALLB_POOL_START = IPAddr.new("192.168.56.200")
METALLB_POOL_END = IPAddr.new("192.168.56.220")

def check_edge_network!
  addresses, status = Open3.capture2("ip", "-j", "address")
  abort "Cannot inspect host addresses before adding the edge network" unless status.success?

  JSON.parse(addresses).each do |interface|
    interface.fetch("addr_info", []).each do |address|
      next unless address["family"] == "inet"

      ip = IPAddr.new(address.fetch("local"))
      next unless EDGE_NETWORK.include?(ip)
      next if interface.fetch("ifname").start_with?("vboxnet") && ip == EDGE_GATEWAY

      abort "Edge subnet #{EDGE_NETWORK_CIDR} conflicts with #{interface.fetch('ifname')} (#{ip}); choose a free host network before vagrant up"
    end
  end

  routes, status = Open3.capture2("ip", "-j", "route")
  abort "Cannot inspect host routes before adding the edge network" unless status.success?

  JSON.parse(routes).each do |route|
    next unless route["dst"] && route["dst"] != "default"

    route_network = IPAddr.new(route["dst"])
    overlaps_edge =
      EDGE_NETWORK.include?(route_network.to_range.first) ||
      route_network.include?(EDGE_NETWORK.to_range.first)

    next unless overlaps_edge
    next if route.fetch("dev", "").start_with?("vboxnet")

    abort "Edge subnet #{EDGE_NETWORK_CIDR} conflicts with host route #{route['dst']} via #{route['dev']}"
  end

  dhcp, status = Open3.capture2("VBoxManage", "list", "dhcpservers")
  abort "Cannot inspect VirtualBox DHCP servers" unless status.success?

  dhcp.split(/(?=^NetworkName:)/).each do |server|
    next unless server.include?("Enabled:        Yes")

    lower = server[/^LowerIPAddress:\s+(\S+)/, 1]
    upper = server[/^UpperIPAddress:\s+(\S+)/, 1]
    next unless lower && upper

    first, last = [lower, upper].map { |value| IPAddr.new(value).to_i }
    overlaps_metallb =
      first <= METALLB_POOL_END.to_i &&
      last >= METALLB_POOL_START.to_i

    next unless overlaps_metallb

    abort "VirtualBox DHCP range #{lower}-#{upper} overlaps reserved MetalLB VIPs #{METALLB_POOL_START}-#{METALLB_POOL_END}; disable or narrow that DHCP range before vagrant up"
  end
end

check_edge_network! if (ARGV & %w[up reload]).any?

control_plane_memory = integer_env("MASTER_MEMORY", 2048)
# node-2 runs ingress, MetalLB, Prometheus and Fluent Bit. At 2-3 GiB it ran
# out of memory and dropped SSH during edge validation.
node_2_memory = integer_env("NODE_2_MEMORY", 4096)
node_3_memory = integer_env("WORKER_MEMORY", 4096)

control_plane_cpus = integer_env("MASTER_CPUS", 2)
worker_cpus = integer_env("WORKER_CPUS", 2)

puts <<~PLAN
  VM resource plan
    base:   #{IMAGE_NAME} #{IMAGE_VERSION}
    node-1: #{control_plane_cpus} CPU / #{control_plane_memory} MB RAM (control plane)
    node-2: #{worker_cpus} CPU / #{node_2_memory} MB RAM (worker)
    node-3: #{worker_cpus} CPU / #{node_3_memory} MB RAM (worker)
  ENV overrides take precedence over deterministic defaults.
PLAN

Vagrant.configure("2") do |config|
  config.ssh.insert_key = true
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.box = IMAGE_NAME
  config.vm.box_version = IMAGE_VERSION

  config.vm.define "node-1" do |machine|
    machine.vm.hostname = "node-1"
    machine.vm.network(
      "private_network",
      ip: "#{CLUSTER_NETWORK_PREFIX}.10",
      virtualbox__intnet: "kubernetes"
    )
    machine.vm.provider "virtualbox" do |virtualbox|
      virtualbox.memory = control_plane_memory
      virtualbox.cpus = control_plane_cpus
    end
  end

  (2..3).each do |index|
    config.vm.define "node-#{index}" do |machine|
      machine.vm.hostname = "node-#{index}"
      machine.vm.network(
        "private_network",
        ip: "#{CLUSTER_NETWORK_PREFIX}.#{index + 9}",
        virtualbox__intnet: "kubernetes"
      )

      # Only workers join the host-accessible edge network; node-1 remains on
      # the private cluster network.
      machine.vm.network(
        "private_network",
        ip: "192.168.56.#{index + 9}"
      )

      machine.vm.provider "virtualbox" do |virtualbox|
        virtualbox.memory = index == 2 ? node_2_memory : node_3_memory
        virtualbox.cpus = worker_cpus
      end

      # The final VM owns the single cluster-wide Ansible run. During a normal
      # `vagrant up`, all three machines exist before this provisioner starts.
      next unless index == 3

      machine.vm.provision "ansible" do |ansible|
        ansible.playbook = "infra/ansible/site.yml"
        ansible.config_file = "infra/ansible/ansible.cfg"
        ansible.compatibility_mode = "2.0"
        ansible.limit = "all"
        ansible.groups = {
          "control_plane" => ["node-1"],
          "workers" => ["node-2", "node-3"],
          "k8s_cluster:children" => ["control_plane", "workers"]
        }
      end
    end
  end
end
