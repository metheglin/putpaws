require 'putpaws/provision/resources/base'

module Putpaws
  module Provision
    module Resources
      class Cluster < Base
        def name
          config.cluster_name
        end

        def current
          res = clients.ecs.describe_clusters(clusters: [name])
          res.clusters.detect{|c| c.status == 'ACTIVE'}
        end

        def create!
          res = clients.ecs.create_cluster(
            cluster_name: name,
            tags: [MANAGED_TAG]
          )
          {cluster_arn: res.cluster.cluster_arn, cluster_name: name}
        end

        def outputs(current)
          {cluster_arn: current.cluster_arn, cluster_name: name}
        end
      end
    end
  end
end
