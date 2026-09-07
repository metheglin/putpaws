require 'json'
require 'digest'
require 'putpaws/provision/resources/base'

module Putpaws
  module Provision
    module Resources
      # Registers an IAM role from a reviewed draft file under policies/.
      # This runs only after the user approved the drafts explicitly
      # (roles.approve_drafts in provision.json). The draft content is applied
      # as-is, including any edits the user made.
      class IamRole < Base
        attr_reader :roles_key, :draft_file
        def initialize(roles_key:, draft_file:, **args)
          super(**args)
          @roles_key = roles_key
          @draft_file = draft_file
        end

        def draft
          @draft ||= begin
            path = config.policies_dir.join(draft_file)
            raise "Role draft not found: #{path}. Please run `putpaws ready` first." unless path.exist?
            JSON.parse(File.read(path), symbolize_names: true)
          end
        end

        def name
          draft[:SuggestedRoleName]
        end

        def policy_name
          draft[:SuggestedPolicyName]
        end

        def digest
          Digest::SHA256.hexdigest(JSON.generate(draft))
        end

        def digest_key
          :"iam_#{roles_key}_digest"
        end

        def current
          clients.iam.get_role(role_name: name).role
        rescue Aws::IAM::Errors::NoSuchEntity, Aws::IAM::Errors::NoSuchEntityException
          nil
        end

        # Re-applied only when the draft content changed since the last apply,
        # so that manual changes on the AWS side are left alone otherwise.
        def changed?(_current)
          state.resources[digest_key] != digest
        end

        def create!
          res = clients.iam.create_role(
            role_name: name,
            assume_role_policy_document: JSON.generate(draft[:AssumeRolePolicyDocument]),
            tags: [MANAGED_TAG]
          )
          put_policy!
          {roles_key => res.role.arn, digest_key => digest}
        end

        def update!(current)
          clients.iam.update_assume_role_policy(
            role_name: name,
            policy_document: JSON.generate(draft[:AssumeRolePolicyDocument])
          )
          put_policy!
          {roles_key => current.arn, digest_key => digest}
        end

        def outputs(current)
          {roles_key => current.arn, digest_key => digest}
        end

        def put_policy!
          clients.iam.put_role_policy(
            role_name: name,
            policy_name: policy_name,
            policy_document: JSON.generate(draft[:PolicyDocument])
          )
        end
      end
    end
  end
end
