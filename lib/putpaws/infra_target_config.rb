require 'pathname'
require 'putpaws/config_file'

# A target part (.putpaws/infra.json: target.<name>): which task definition
# to start on which cluster. Parts do not belong to an environment.
class Putpaws::InfraTargetConfig < Struct.new(
  :name,
  :scheduler_role,
  :cluster,
  :task_definition,
  :container_name,
  keyword_init: true)
  def self.load(path_prefix: Putpaws::ConfigFile.root)
    data = Putpaws::ConfigFile.read(Pathname.new(path_prefix).join("infra.json"))
    data[:target] || {}
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

  def cluster_arn?
    cluster.to_s.start_with?('arn:')
  end

  # Region of the cluster ARN. nil when `cluster` is a bare name.
  def cluster_region
    cluster_arn? ? cluster.to_s.split(':')[3] : nil
  end

  def cluster_name
    cluster.to_s.split('/').last
  end
end
