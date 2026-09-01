require 'putpaws/provision/util'
require 'putpaws/provision/resources/base'

module Putpaws
  module Provision
    module Resources
      # When base.security_group_ids is set, the existing security groups are
      # used as-is (putpaws never touches their rules). Otherwise a new one is
      # created with no ingress rules (egress open by default).
      # Ingress for ALB etc. is out of scope: add manually or by another command.
      class SecurityGroup < Base
        def specified_ids
          ids = Array(config.base[:security_group_ids])
          # backward compatible with the singular key
          ids = [config.base[:security_group_id]] if ids.empty?
          ids.reject{|x| Util.blank?(x)}
        end

        def specified?
          specified_ids.any?
        end

        def name
          specified? ? "#{specified_ids.join(', ')} (existing)" : config.sg_name
        end

        def current
          return current_specified if specified?
          res = clients.ec2.describe_security_groups(filters: [
            {name: 'group-name', values: [name]},
            {name: 'vpc-id', values: [config.base[:vpc_id]]},
          ])
          res.security_groups.first
        end

        def current_specified
          res = begin
            clients.ec2.describe_security_groups(group_ids: specified_ids)
          rescue Aws::EC2::Errors::InvalidGroupNotFound
            raise "Specified security group not found: #{specified_ids.join(', ')}"
          end
          found = res.security_groups
          missing = specified_ids - found.map(&:group_id)
          raise "Specified security group not found: #{missing.join(', ')}" if missing.any?
          wrong = found.reject{|sg| sg.vpc_id == config.base[:vpc_id]}
          if wrong.any?
            sg = wrong.first
            raise "Security group #{sg.group_id} belongs to #{sg.vpc_id}, not #{config.base[:vpc_id]}"
          end
          found
        end

        def create!
          res = clients.ec2.create_security_group(
            group_name: name,
            description: "Managed by putpaws for #{config.service_name}",
            vpc_id: config.base[:vpc_id],
            tag_specifications: [
              {resource_type: 'security-group', tags: [MANAGED_TAG]}
            ]
          )
          {security_group_ids: [res.group_id]}
        end

        def outputs(current)
          ids = current.is_a?(Array) ? current.map(&:group_id) : [current.group_id]
          {security_group_ids: ids}
        end
      end
    end
  end
end
