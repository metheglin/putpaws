require 'putpaws/provision/resources/base'

module Putpaws
  module Provision
    module Resources
      class Service < Base
        def name
          config.service_name
        end

        def desired_count
          (config.settings[:desired_count] || 1).to_i
        end

        def task_definition_family
          config.service_task_definition_family
        end

        def security_group_ids
          ids = state.resources[:security_group_ids]
          raise "security_group_ids not found in state. Run the security group step first." if ids.nil? || ids.empty?
          ids
        end

        def current
          res = clients.ecs.describe_services(cluster: config.cluster_name, services: [name])
          res.services.detect{|s| s.status == 'ACTIVE'}
        end

        def changed?(current)
          current_family = current.task_definition.to_s.split('/').last.to_s.split(':').first
          current_family != task_definition_family || current.desired_count != desired_count
        end

        def create!
          res = clients.ecs.create_service(
            cluster: config.cluster_name,
            service_name: name,
            task_definition: task_definition_family,
            desired_count: desired_count,
            launch_type: 'FARGATE',
            enable_execute_command: true,
            network_configuration: {
              awsvpc_configuration: {
                subnets: config.base[:subnets],
                security_groups: security_group_ids,
                assign_public_ip: config.settings[:assign_public_ip] || 'DISABLED',
              }
            },
            tags: [MANAGED_TAG]
          )
          {service_arn: res.service.service_arn, service_name: name}
        end

        def update!(_current)
          res = clients.ecs.update_service(
            cluster: config.cluster_name,
            service: name,
            task_definition: task_definition_family,
            desired_count: desired_count
          )
          {service_arn: res.service.service_arn, service_name: name}
        end

        def outputs(current)
          {service_arn: current.service_arn, service_name: name}
        end
      end
    end
  end
end
