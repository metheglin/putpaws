require 'json'
require 'pathname'
require 'putpaws/infra_network_config'
require 'putpaws/infra_target_config'

class Putpaws::ScheduleConfig < Struct.new(
  :name, :region, :network, :target, :command, :args,
  keyword_init: true)
  def self.load(path_prefix: '.putpaws')
    @schedule_data ||= begin
      path = Pathname.new(path_prefix).join("schedule.json").to_s
      data = File.exist?(path) ?
        JSON.parse(File.read(path), symbolize_names: true).to_h :
        {}
    end
  end

  def self.build_args(name, config_args)
    region = config_args.delete(:region)
    network = config_args.delete(:network)
    target = config_args.delete(:target)
    command = config_args.delete(:command)
    {
      name: name.to_s, 
      region: region, 
      network: network, 
      target: target, 
      command: command,
    }.merge(args: config_args)
  end

  def self.all
    load.map{|k,v|
      new(build_args(k, v))
    }
  end

  def self.find(name)
    schedule_data = load
    data = schedule_data[name.to_sym]
    return nil unless data
    new(build_args(name, data))
  end

  def network
    return nil unless self[:network]
    @network ||= Putpaws::InfraNetworkConfig.find(self[:network])
  end

  def target
    return nil unless self[:target]
    @target ||= Putpaws::InfraTargetConfig.find(self[:target])
  end
end
