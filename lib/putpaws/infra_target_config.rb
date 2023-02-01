require 'json'
require 'pathname'

class Putpaws::InfraTargetConfig < Struct.new(
  :name, 
  :scheduler_role,
  :cluster,
  :task_definition,
  :container_name,
  keyword_init: true)
  def self.load(path_prefix: '.putpaws')
    @infra_target_data ||= begin
      path = Pathname.new(path_prefix).join("infra.json").to_s
      data = File.exists?(path) ?
        JSON.parse(File.read(path), symbolize_names: true).to_h :
        {}
      data[:target] || {}
    end
  end

  def self.all
    load.map{|k,v|
      data = v.slice(*self.members)
      new(data.merge(name: k.to_s))
    }
  end

  def self.find(name)
    infra_target_data = load
    data = infra_target_data[name.to_sym]
    return nil unless data
    data = data.slice(*self.members)
    new(data.merge({name: name.to_s}))
  end
end
