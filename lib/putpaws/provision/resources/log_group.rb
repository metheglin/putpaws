require 'putpaws/provision/resources/base'

module Putpaws
  module Provision
    module Resources
      class LogGroup < Base
        def initialize(log_group_name:, output_key:, **args)
          super(**args)
          @log_group_name = log_group_name
          @output_key = output_key
        end

        def name
          @log_group_name
        end

        def retention_in_days
          (config.settings[:log_retention_days] || 30).to_i
        end

        def current
          res = clients.logs.describe_log_groups(log_group_name_prefix: name)
          res.log_groups.detect{|g| g.log_group_name == name}
        end

        def changed?(current)
          current.retention_in_days != retention_in_days
        end

        def create!
          clients.logs.create_log_group(
            log_group_name: name,
            tags: {MANAGED_TAG[:key] => MANAGED_TAG[:value]}
          )
          clients.logs.put_retention_policy(log_group_name: name, retention_in_days: retention_in_days)
          {@output_key => name}
        end

        def update!(_current)
          clients.logs.put_retention_policy(log_group_name: name, retention_in_days: retention_in_days)
          {@output_key => name}
        end

        def outputs(_current)
          {@output_key => name}
        end
      end
    end
  end
end
