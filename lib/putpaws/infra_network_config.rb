require 'json'
require 'pathname'

class Putpaws::InfraNetworkConfig < Struct.new(
  :name, :subnets, :security_groups, :assign_public_ip,
  keyword_init: true)
  def self.load(path_prefix: '.putpaws')
    @infra_network_data ||= begin
      path = Pathname.new(path_prefix).join("infra.json").to_s
      data = File.exist?(path) ?
        JSON.parse(File.read(path), symbolize_names: true).to_h :
        {}
      data[:network] || {}
    end
  end

  def self.all
    load.map{|k,v|
      data = v.slice(*self.members)
      new(data.merge(name: k.to_s))
    }
  end

  def self.find(name)
    infra_network_data = load
    data = infra_network_data[name.to_sym]
    return nil unless data
    data = data.slice(*self.members)
    new(data.merge({name: name.to_s}))
  end
end
