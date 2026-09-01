require 'putpaws/provision/util'
require 'putpaws/provision/preset'
require 'putpaws/provision/provision_config'
require 'putpaws/provision/state'
require 'putpaws/provision/aws_clients'
require 'putpaws/provision/policy_generator'
require 'putpaws/provision/config_writer'
require 'putpaws/provision/runner'

module Putpaws
  module Provision
    # Resolve which service to operate on: ENV['service'], the only one,
    # or an interactive selection.
    def self.resolve_config(path_prefix: '.putpaws')
      name = ENV['service']
      if Util.blank?(name)
        services = ProvisionConfig.services(path_prefix: path_prefix)
        raise "No provisioned service found. Please run `putpaws ready` first." if services.empty?
        name = if services.one?
          services.first
        else
          require 'putpaws/prompt'
          Putpaws::Prompt.safe.select("Choose a service", services)
        end
      end
      ProvisionConfig.load(name, path_prefix: path_prefix)
    end
  end
end
