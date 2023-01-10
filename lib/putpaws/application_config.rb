require 'json'

class Putpaws::ApplicationConfig < Struct.new(
  :name, :region, 
  :cluster, :service, :task_name_prefix, 
  :log_group_prefix, :log_region,
  keyword_init: true)
  def self.load(path_prefix: '.putpaws')
    @application_data ||= begin
      path = Pathname.new(path_prefix).join("application.json").to_s
      data = File.exists?(path) ?
        JSON.parse(File.read(path), symbolize_names: true).to_h :
        {}
    end
  end

  def self.all
    load.map{|k,v|
      data = v.slice(*self.members)
      new(data.merge(name: k.to_s))
    }
  end

  def self.find(name)
    application_data = load
    data = application_data[name.to_sym]
    return nil unless data
    data = data.slice(*self.members)
    new(data.merge({name: name.to_s}))
  end

  def log_command_params
    {
      region: log_region || region,
      log_group_prefix: log_group_prefix,
    }
  end
end
