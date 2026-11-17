require 'pathname'
require 'putpaws/config_file'

# A network part (.putpaws/infra.json: network.<name>).
# Parts do not belong to an environment; they are shared by all of them.
class Putpaws::InfraNetworkConfig < Struct.new(
  :name, :subnets, :security_groups, :assign_public_ip,
  keyword_init: true)
  def self.load(path_prefix: Putpaws::ConfigFile.root)
    data = Putpaws::ConfigFile.read(Pathname.new(path_prefix).join("infra.json"))
    data[:network] || {}
  end

  def self.all(path_prefix: Putpaws::ConfigFile.root)
    load(path_prefix: path_prefix).map{|k, v|
      new(v.slice(*members).merge(name: k.to_s))
    }
  end

  def self.find(name, path_prefix: Putpaws::ConfigFile.root)
    data = load(path_prefix: path_prefix)[name.to_sym]
    return nil unless data
    new(data.slice(*members).merge(name: name.to_s))
  end
end
