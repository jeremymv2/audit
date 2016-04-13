# encoding: utf-8
# `compliance_report` custom resource to run Chef Compliance profiles and
# send reports to Chef Compliance
class ComplianceReport < Chef::Resource
  include ComplianceHelpers
  use_automatic_resource_name

  property :name, String, name_property: true

  # to use a chef-compliance server that is _not_ "colocated" with chef-server
  property :server, URI
  property :port, Integer
  property :token, String
  property :variant, String, default: 'chef' # 'chef', 'compliance'

  # to override the node this report is reported for
  property :node, String # default: node.name
  property :environment, String # default: node.environment
  property :owner, String

  default_action :execute

  action :execute do
    converge_by "report compliance profiles' results" do
      reports, ownermap = compound_report(profiles)

      blob = node_info
      blob[:reports] = reports
      blob[:profiles] = ownermap

      # resolve owner
      o = return_or_guess_owner

      if token
        if variant == 'compliance'
          url = construct_url(::File.join('/owners', o, 'inspec'), server)
        elsif variant == 'chef'
          url = construct_url(::File.join('/chef/organizations', o, 'inspec'), server)
        else
          raise "Provided unknown variant: #{variant}"
        end
        req = Net::HTTP::Post.new(url, { 'Authorization' => "Bearer #{token}" })
        req.body = blob.to_json

        Net::HTTP.start(url.host, url.port) do |http|
          http.use_ssl = url.scheme == 'https'
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE # FIXME

          http.request(req)
        end
      else
        Chef::Config[:verify_api_cert] = false
        Chef::Config[:ssl_verify_mode] = :verify_none

        url = construct_url(::File.join('/organizations', o, 'inspec'))
        rest = Chef::ServerAPI.new(url, Chef::Config)
        rest.post(url, blob)
      end
    end
  end

  # filters resource collection
  def profiles
    run_context.resource_collection.select do |r|
      r.is_a?(ComplianceProfile)
    end.flatten
  end

  def compound_report(*profiles)
    report = {}
    ownermap = {}

    profiles.flatten.each do |prof|
      o, p = prof.normalize_owner_profile
      report[p] = ::JSON.parse(::File.read(prof.report_path))
      ownermap[p] = o
    end

    [report, ownermap]
  end

  def node_info
    n = run_context.node
    {
      node: n.name,
      os: {
        # arch: os[:arch],
        release: n['platform_version'],
        family: n['platform'],
      },
      environment: environment || n.environment,
    }
  end

  def return_or_guess_owner
    owner || Chef::Config[:chef_server_url].split('/').last
  end
end
