require "open3"
require "ipaddr"
require "json"

def integer_env(name, fallback)
  value = ENV.fetch(name, fallback).to_s
  Integer(value, 10)
rescue ArgumentError
  abort "#{name} must be an integer, got #{value.inspect}"
end

def existing_machine_memory_mb(name)
  id_path = File.join(__dir__, ".vagrant/machines", name, "virtualbox/id")
  return unless File.file?(id_path)

  clean_environment = { "LD_LIBRARY_PATH" => nil, "LD_PRELOAD" => nil }
  details, status = Open3.capture2(
    clean_environment,
    "VBoxManage", "showvminfo", File.read(id_path).strip, "--machinereadable"
  )
  return unless status.success?

  details[/^memory=(\d+)$/, 1]&.to_i
end

def available_memory_mb
  if File.readable?("/proc/meminfo")
    value_kb = File.read("/proc/meminfo")[/^MemAvailable:\s+(\d+)\s+kB$/, 1]
    return value_kb.to_i / 1024 if value_kb
  end

  value_bytes = `sysctl -n hw.memsize 2>/dev/null`.strip
  return value_bytes.to_i / 1024 / 1024 unless value_bytes.empty?

  abort "Unable to detect host memory. Set MASTER_MEMORY and WORKER_MEMORY explicitly."
end

def adaptive_memory(available_mb)
  return [4096, 3072, "large"] if available_mb >= 20_000
  return [3072, 2560, "medium"] if available_mb >= 12_000
  return [2560, 2048, "small"] if available_mb >= 8_000
  return [2048, 1536, "constrained"] if available_mb >= 7_000
  return [2048, 1536, "low-memory"] if available_mb >= 6_000

  unless (ARGV & %w[up reload resume]).any? &&
         !(ENV.key?("MASTER_MEMORY") && ENV.key?("WORKER_MEMORY"))
    return [2048, 1536, "low-memory"]
  end

  abort <<~MESSAGE
    Only #{available_mb} MB of host memory is available. At least 6000 MB is required
    to start the default three-node lab. Free memory or set MASTER_MEMORY and
    WORKER_MEMORY explicitly if you accept the risk of host pressure.
  MESSAGE
end

IMAGE_NAME = ENV.fetch("IMAGE_NAME", "ubuntu/focal64")
BASE_IP = ENV.fetch("BASE_IP", "10.50.0")
EDGE_CIDR = IPAddr.new("192.168.56.0/24")

def check_edge_network!
  addresses, status = Open3.capture2("ip", "-j", "address")
  abort "Cannot inspect host addresses before adding the edge network" unless status.success?
  JSON.parse(addresses).each do |interface|
    interface.fetch("addr_info", []).each do |address|
      next unless address["family"] == "inet"
      ip = IPAddr.new(address.fetch("local"))
      next unless EDGE_CIDR.include?(ip)
      next if interface.fetch("ifname").start_with?("vboxnet") && ip.to_s == "192.168.56.1"
      abort "Edge subnet 192.168.56.0/24 conflicts with #{interface.fetch('ifname')} (#{ip}); choose a free host network before vagrant up"
    end
  end

  routes, status = Open3.capture2("ip", "-j", "route")
  abort "Cannot inspect host routes before adding the edge network" unless status.success?
  JSON.parse(routes).each do |route|
    next unless route["dst"] && route["dst"] != "default"
    route_network = IPAddr.new(route["dst"])
    next unless EDGE_CIDR.include?(route_network.to_range.first) || route_network.include?(EDGE_CIDR.to_range.first)
    next if route.fetch("dev", "").start_with?("vboxnet")
    abort "Edge subnet 192.168.56.0/24 conflicts with host route #{route['dst']} via #{route['dev']}"
  end

  dhcp, status = Open3.capture2("VBoxManage", "list", "dhcpservers")
  abort "Cannot inspect VirtualBox DHCP servers" unless status.success?
  dhcp.split(/(?=^NetworkName:)/).each do |server|
    next unless server.include?("Enabled:        Yes")
    lower = server[/^LowerIPAddress:\s+(\S+)/, 1]
    upper = server[/^UpperIPAddress:\s+(\S+)/, 1]
    next unless lower && upper
    first, last = [lower, upper].map { |value| IPAddr.new(value).to_i }
    next unless first <= IPAddr.new("192.168.56.220").to_i && last >= IPAddr.new("192.168.56.200").to_i
    abort "VirtualBox DHCP range #{lower}-#{upper} overlaps the reserved MetalLB VIPs; disable or narrow that DHCP range before vagrant up"
  end
end

check_edge_network! if (ARGV & %w[up reload]).any?

available_mb = available_memory_mb
existing_master_memory = existing_machine_memory_mb("node-1")
existing_worker_memory = existing_machine_memory_mb("node-3")
if existing_master_memory && existing_worker_memory
  default_master_memory = existing_master_memory
  default_worker_memory = existing_worker_memory
  memory_tier = "existing"
else
  default_master_memory, default_worker_memory, memory_tier = adaptive_memory(available_mb)
end
master_memory = integer_env("MASTER_MEMORY", 2048)
worker_memory = integer_env("WORKER_MEMORY", 4096)
node_2_memory = integer_env("NODE_2_MEMORY", 2048)
master_cpus = integer_env("MASTER_CPUS", 2)
worker_cpus = integer_env("WORKER_CPUS", 2)

puts <<~PLAN
  Stage 1 resource plan (#{memory_tier} tier, #{available_mb} MB host memory currently available)
    node-1: #{master_cpus} CPU / #{master_memory} MB RAM (control plane)
    node-2: #{worker_cpus} CPU / #{node_2_memory} MB RAM (worker, locally constrained)
    node-3: #{worker_cpus} CPU / #{worker_memory} MB RAM (worker)
  ENV overrides take precedence over adaptive defaults.
PLAN

Vagrant.configure("2") do |config|
  config.ssh.insert_key = false
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define "node-1" do |machine|
    machine.vm.box = IMAGE_NAME
    machine.vm.hostname = "node-1"
    machine.vm.network "private_network", ip: "#{BASE_IP}.10", virtualbox__intnet: "kubernetes"
    machine.vm.provider "virtualbox" do |virtualbox|
      virtualbox.memory = master_memory
      virtualbox.cpus = master_cpus
    end
  end

  (2..3).each do |index|
    config.vm.define "node-#{index}" do |machine|
      machine.vm.box = IMAGE_NAME
      machine.vm.hostname = "node-#{index}"
      machine.vm.network "private_network", ip: "#{BASE_IP}.#{index + 9}", virtualbox__intnet: "kubernetes"
      # Only workers join the host-accessible network; node-1 stays private.
      machine.vm.network "private_network", ip: "192.168.56.#{index + 9}", name: "vboxnet0"
      machine.vm.provider "virtualbox" do |virtualbox|
        virtualbox.memory = index == 2 ? node_2_memory : worker_memory
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
